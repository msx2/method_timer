# frozen_string_literal: true

require_relative 'method_timer/version'
require_relative 'method_timer/recorder'
require_relative 'method_timer/instrumenter'
require_relative 'method_timer/reporter'
require_relative 'method_timer/sql'
require_relative 'method_timer/memory'

# Times every method under a class or namespace, reporting self/total time, SQL time, GC time, allocations and
# call counts. See README.md for usage and how to read the report.
#
# The parts are modules extended onto MethodTimer, so they share its state and the generated wrappers call
# MethodTimer.enter / MethodTimer.leave directly, without an extra object per call.
module MethodTimer
  extend Recorder
  extend Instrumenter
  extend Reporter
  extend Sql
  extend Memory

  @depth = 0
  @thread = nil
  @instrumented = {}
  @grand_total = 0.0
  @overhead = 0.0
  @root = nil
  @strip_root = true
  @common_prefix = ''
  @name_width = 65

  class << self
    def run(rss: false)
      reset
      subscriber = subscribe_sql { |start, finish| record_sql(start, finish) }
      GC.start
      @rss_start = @rss_peak = rss ? current_rss : nil
      sampler = start_rss_sampler if rss
      @thread = Thread.current
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      @grand_total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      @thread = nil
      if rss
        @rss_end = current_rss
        @rss_peak = [@rss_start, stop_rss_sampler(sampler), @rss_end].compact.max
      end
      unsubscribe_sql(subscriber)
      report
    end

    def bench(rss: false)
      sql = [0.0, 0] # [time, calls]
      subscriber = subscribe_sql do |start, finish|
        sql[0] += finish - start
        sql[1] += 1
      end
      GC.start
      @rss_start = @rss_peak = rss ? current_rss : nil
      sampler = start_rss_sampler if rss
      start = [Process.clock_gettime(Process::CLOCK_MONOTONIC), GC.stat(:time), GC.stat(:total_allocated_objects)]
      yield
    ensure
      unsubscribe_sql(subscriber)
      report_bench(start, sql, rss, sampler) if start
    end
  end
end
