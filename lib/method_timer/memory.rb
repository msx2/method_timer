# frozen_string_literal: true

module MethodTimer
  # Process memory (RSS) sampling for `run(rss: true)` and `bench(rss: true)`.
  module Memory
    RSS_INTERVAL = 1 # seconds
    # Args: $1 = PID to watch, $2 = interval in seconds. Prints the peak RSS in KB on SIGTERM. POSIX sh only
    # (dash, busybox ash, bash, macOS sh). Linux reads VmRSS from /proc (kB, independent of page size), other
    # systems use ps. The sleep doesn't hold stdout, so the pipe closes as soon as the script exits.
    RSS_SAMPLER_SCRIPT = <<~SH
      peak=0
      trap 'echo "$peak"; exit 0' TERM
      while kill -0 "$1" 2>/dev/null; do
        rss=
        if [ -r "/proc/$1/status" ]; then
          while read -r key value _; do
            [ "$key" = "VmRSS:" ] && rss=$value
          done < "/proc/$1/status"
        else
          rss=$(ps -o rss= -p "$1" | tr -d ' ')
        fi
        [ -n "$rss" ] && [ "$rss" -gt "$peak" ] && peak=$rss
        sleep "$2" > /dev/null 2>&1 &
        wait $!
      done
      echo "$peak"
    SH

    private

    # Samples the peak RSS from a child shell process, so sampling allocates nothing in this process and can't
    # skew allocs or self(gc). The child keeps the maximum and prints it (in KB) once, when stopped.
    def start_rss_sampler
      reader, writer = IO.pipe
      pid = Process.spawn('sh', '-c', RSS_SAMPLER_SCRIPT, 'rss_sampler', Process.pid.to_s, RSS_INTERVAL.to_s,
                          out: writer, err: File::NULL)
      writer.close
      [pid, reader]
    rescue SystemCallError
      reader&.close
      writer&.close
      nil
    end

    # Stops the sampler and returns the peak RSS it saw, in bytes (nil if unavailable).
    def stop_rss_sampler(sampler)
      return unless sampler

      pid, reader = sampler
      Process.kill('TERM', pid)
      peak_kb = reader.read.to_i
      Process.wait(pid)
      peak_kb.positive? ? peak_kb * 1024 : nil
    rescue SystemCallError
      nil
    ensure
      reader&.close
    end

    # RSS in bytes. Linux: /proc/self/statm. macOS/other: shell out to ps. Returns nil if unavailable.
    def current_rss
      if File.exist?('/proc/self/status')
        File.read('/proc/self/status')[/^VmRSS:\s+(\d+)/, 1].to_i * 1024 # kB, independent of page size
      else
        `ps -o rss= -p #{Process.pid}`.to_i * 1024 # ps reports KB
      end
    rescue StandardError
      nil
    end
  end
end
