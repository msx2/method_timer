# frozen_string_literal: true

module MethodTimer
  # Collects per-method stats during a run.
  module Recorder
    # Per-method stats, indexed by method id: [self_t, sql_t, gc_ms, total_t, calls, sql_calls, allocs]
    NAMES = []
    STATS = []
    # Per-depth frame data; depth 0 is the code running outside instrumented methods.
    START_T = [0.0]
    START_A = [0]
    START_G = [0]
    CHILD_T = [0.0]
    CHILD_A = [0]
    CHILD_G = [0]
    SQL_T = [0.0]
    SQL_N = [0]

    def reset
      STATS.map! { [0.0, 0.0, 0, 0.0, 0, 0, 0] }
      @depth = 0
      @grand_total = 0.0
    end

    # { "Class#method" => { self_t:, sql_t:, gc_t:, total_t:, calls:, sql_calls:, allocs: } } for called methods
    def stats
      STATS.each_with_index.filter_map do |(self_t, sql_t, gc_ms, total_t, calls, sql_calls, allocs), id|
        next if calls.zero?

        [NAMES[id], { self_t:, sql_t:, gc_t: gc_ms / 1000.0, total_t:, calls:, sql_calls:, allocs: }]
      end.to_h
    end

    # Called by every wrapper. Kept allocation-free (flat arrays, no blocks or splats) so that profiling
    # millions of calls neither skews the allocation counts nor triggers extra GC. Frame state is global, so
    # calls from any thread other than the one running `run` are ignored instead of corrupting it.
    def enter
      return unless Thread.current.equal?(@thread)

      d = @depth += 1
      CHILD_T[d] = 0.0
      CHILD_A[d] = 0
      CHILD_G[d] = 0
      SQL_T[d] = 0.0
      SQL_N[d] = 0
      START_G[d] = GC.stat(:time)
      START_A[d] = GC.stat(:total_allocated_objects)
      START_T[d] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def leave(id)
      return unless Thread.current.equal?(@thread)

      d = @depth
      total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - START_T[d]
      allocs = GC.stat(:total_allocated_objects) - START_A[d]
      gc_ms = GC.stat(:time) - START_G[d]
      @depth = d - 1
      record(STATS[id], d, total, allocs, gc_ms)
      CHILD_T[d - 1] += total
      CHILD_A[d - 1] += allocs
      CHILD_G[d - 1] += gc_ms
    end

    private

    def record(stat, depth, total, allocs, gc_ms)
      stat[0] += total - CHILD_T[depth]
      stat[1] += SQL_T[depth] # SQL fired directly in this method (not in instrumented children)
      stat[2] += gc_ms - CHILD_G[depth] # GC pauses that started directly in this method
      stat[3] += total
      stat[4] += 1
      stat[5] += SQL_N[depth]
      stat[6] += allocs - CHILD_A[depth] # objects allocated directly in this method
    end

    def record_sql(start, finish)
      return if @depth.zero? || !Thread.current.equal?(@thread)

      SQL_T[@depth] += finish - start
      SQL_N[@depth] += 1
    end

    def register(name)
      NAMES << name.freeze
      STATS << [0.0, 0.0, 0, 0.0, 0, 0, 0]
      NAMES.size - 1
    end
  end
end
