# frozen_string_literal: true

module MethodTimer
  # Wraps every method of the instrumented classes (and their directly included modules) in a prepended module
  # that calls MethodTimer.enter / MethodTimer.leave around it.
  module Instrumenter
    CALIBRATION_CALLS = 200_000

    def install(root, silence_sql: true, strip_root: true)
      @root = root
      @strip_root = strip_root
      ActiveRecord::Base.logger = nil if silence_sql && defined?(ActiveRecord::Base)
      classes = []
      classes << root if root.is_a?(Class)
      each_class(root) { |k| classes << k }
      sources = classes.flat_map { |k| [k, *own_included_modules(k)] }
      @common_prefix = common_namespace(sources.filter_map(&:name))
      already = @instrumented.size
      classes.each { |k| instrument(k) }
      calibrate
      warn "MethodTimer: instrumented #{@instrumented.size - already} classes/modules under #{root} " \
           '(overhead %.2fµs per call).' % (@overhead * 1e6)
    end

    # Removes every wrapper added by `install`, so instrumented methods run at full speed again and a different
    # class or namespace can be installed from scratch. A module can't be un-prepended, but an emptied one adds
    # no per-call cost.
    def uninstall
      @instrumented.each_value do |wrapper|
        (wrapper.instance_methods(false) + wrapper.private_instance_methods(false)).each do |m|
          wrapper.send(:remove_method, m)
        end
      end
      count = @instrumented.size
      @instrumented.clear
      reset
      count
    end

    # Longest `::`-delimited namespace shared by all names, always leaving at least the leaf segment.
    def common_namespace(names)
      return '' if names.empty?
      parts = names.map { |n| n.split('::') }
      min_len = parts.map(&:size).min
      shared = (0...min_len).take_while { |i| parts.map { |p| p[i] }.uniq.size == 1 }.size
      shared = min_len - 1 if shared >= min_len
      parts.first.first(shared).join('::')
    end

    private

    # Times an empty instrumented method against a plain one to estimate the fixed cost of each wrapper call.
    def calibrate
      plain = Class.new { def noop = nil }
      timed = Class.new { def noop = nil }
      wrapper = Module.new
      @calibration_id ||= register('MethodTimer#calibration')
      define_wrapper(wrapper, :noop, @calibration_id)
      timed.prepend(wrapper)
      @thread = Thread.current
      @overhead = [elapsed(timed.new) - elapsed(plain.new), 0.0].max / CALIBRATION_CALLS
    ensure
      @thread = nil
      @depth = 0
      Recorder::STATS[@calibration_id] = [0.0, 0.0, 0, 0.0, 0, 0, 0] if @calibration_id
    end

    def elapsed(object)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      CALIBRATION_CALLS.times { object.noop }
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    end

    def each_class(mod, seen = {}, &blk)
      return if seen[mod]
      seen[mod] = true
      mod.constants(false).each do |c|
        val = mod.const_get(c)
        next unless val.is_a?(Module) && val.name&.start_with?(mod.name.to_s)
        yield(val) if val.is_a?(Class)
        each_class(val, seen, &blk)
      end
    rescue StandardError
      nil
    end

    # Strips the namespace shared by all instrumented sources, so labels stay short yet unique
    # (a single fixed prefix removed from already-unique names cannot collide).
    def label_for(klass)
      return klass.name unless @strip_root && klass.name && !@common_prefix.to_s.empty?
      klass.name.sub(/\A#{Regexp.escape(@common_prefix)}::/, '')
    end

    def instrument(klass)
      instrument_owner(klass)
      own_included_modules(klass).each { |mod| instrument_owner(mod) }
    end

    # Prepend a timing wrapper into the method owner itself (class or module) so that each ancestor
    # layer is measured independently: a method reached via `super` still records its own-owner timing.
    def instrument_owner(source)
      return if @instrumented[source]
      wrapper = @instrumented[source] = Module.new
      wrap_methods(wrapper, source, label_for(source))
      source.prepend(wrapper)
    end

    # Modules mixed directly into klass (not inherited from its superclass, not anonymous wrappers).
    def own_included_modules(klass)
      inherited = klass.superclass ? klass.superclass.ancestors : []
      (klass.ancestors - inherited).select { |a| a.instance_of?(Module) && a != klass && a.name }
    end

    def wrap_methods(wrapper, source, label)
      privates = source.private_instance_methods(false)
      protecteds = source.protected_instance_methods(false)
      methods = source.instance_methods(false) + privates
      methods.each do |m|
        define_wrapper(wrapper, m, register("#{label}##{m}"))
        wrapper.send(:private, m) if privates.include?(m)
        wrapper.send(:protected, m) if protecteds.include?(m)
      end
    end

    # `(...)` with a bare `super` forwards arguments without allocating, unlike `define_method { |*a, **k| }`.
    def define_wrapper(wrapper, method_name, id)
      wrapper.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        def #{method_name}(...)
          MethodTimer.enter
          super
        ensure
          MethodTimer.leave(#{id})
        end
      RUBY
    rescue SyntaxError
      wrapper.define_method(method_name) do |*a, **k, &b|
        MethodTimer.enter
        super(*a, **k, &b)
      ensure
        MethodTimer.leave(id)
      end
    end
  end
end
