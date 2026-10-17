# frozen_string_literal: true

module MethodTimer
  # Prints the `run` and `bench` reports to stderr.
  module Reporter
    def report(threshold: 0.001)
      all = stats
      @name_width = [65, *all.keys.map(&:length)].max
      warn "\n%-*s %10s %10s %10s %10s %10s %10s %12s" %
        [@name_width, 'method', 'self(ruby)', 'self(sql)', 'self(gc)', 'total', 'calls', 'sql calls', 'allocs']
      warn '-' * (@name_width + 79)
      all.sort_by { |_, v| -self_ruby(v) }.each do |name, v|
        next if v[:total_t] < threshold
        warn '%-*s %9.5fs %9.5fs %9.5fs %9.5fs %10d %10d %12d' %
          [@name_width, name, self_ruby(v), v[:sql_t], v[:gc_t], v[:total_t], v[:calls], v[:sql_calls], v[:allocs]]
      end
      warn '-' * (@name_width + 79)
      report_totals(all.values)
      report_rss("peak (sampled every #{Memory::RSS_INTERVAL}s)") if @rss_peak
      warn '-' * (@name_width + 79)
    end

    private

    def self_ruby(stats)
      stats[:self_t] - stats[:sql_t] - stats[:gc_t]
    end

    def report_totals(values)
      w = @name_width
      calls = values.sum { |v| v[:calls] }
      sql_t = values.sum { |v| v[:sql_t] }
      sql_calls = values.sum { |v| v[:sql_calls] }
      gc_t = values.sum { |v| v[:gc_t] }
      allocs = values.sum { |v| v[:allocs] }
      warn '%-*s %10s %10s %10s %9.5fs' % [w, 'TOTAL (wall time of run block)', '', '', '', @grand_total]
      warn '%-*s %9.5fs' % [w, '  of which captured (sum of self ruby)', values.sum { |v| self_ruby(v) }]
      warn '%-*s %10s %9.5fs %10s %10s %10s %10d' % [w, '  of which SQL (sum of self sql / calls)', '', sql_t,
                                                     '', '', '', sql_calls]
      warn '%-*s %10s %10s %9.5fs' % [w, '  of which GC (sum of self gc)', '', '', gc_t]
      warn '%-*s %9.5fs  (%d calls x %.2fµs, counted in callers\' self)' %
        [w, '  of which instrumentation overhead (estimated)', calls * @overhead, calls, @overhead * 1e6]
      warn '%-*s %10s %10s %10s %10s %10s %10s %12d' % [w, '  total allocations (sum of self allocs)', '', '', '', '',
                                                        '', '', allocs]
    end

    def report_bench((t0, gc0, alloc0), (sql_t, sql_calls), rss, sampler)
      warn "\n%-20s %9.3fs" % ['wall', Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0]
      warn '%-20s %9.3fs' % ['GC', (GC.stat(:time) - gc0) / 1000.0]
      warn '%-20s %9.3fs (%d queries)' % ['SQL', sql_t, sql_calls]
      warn '%-20s %10d' % ['allocations', GC.stat(:total_allocated_objects) - alloc0]
      return unless rss

      @rss_end = current_rss
      @rss_peak = [@rss_start, stop_rss_sampler(sampler), @rss_end].compact.max
      report_rss("peak (sampled every #{Memory::RSS_INTERVAL}s)")
    end

    def report_rss(peak_label = 'peak')
      warn ''
      warn '%-*s %10s' % [@name_width, '  RSS start', format_bytes(@rss_start)]
      warn '%-*s %10s' % [@name_width, "  RSS #{peak_label}", format_bytes(@rss_peak)]
      warn '%-*s %10s' % [@name_width, '  RSS end', format_bytes(@rss_end)]
      return unless @rss_peak && @rss_start

      warn '%-*s %10s' % [@name_width, '  RSS growth (peak - start)', format_bytes(@rss_peak - @rss_start)]
    end

    def format_bytes(bytes)
      return '-' unless bytes
      value = bytes.to_f
      %w[B KB MB GB].each do |unit|
        return '%.1f%s' % [value, unit] if value < 1024 || unit == 'GB'
        value /= 1024
      end
    end
  end
end
