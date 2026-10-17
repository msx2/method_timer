# frozen_string_literal: true

RSpec.describe MethodTimer do
  let(:target_class) do
    Class.new do
      def counted = nil

      def outer = inner

      def inner = sleep(0.002)

      def collect
        GC.start
      end

      def caller_of_collect = collect

      def query(cached: false)
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT 1', name: 'Load', cached:)
        :queried
      end
    end
  end
  let(:target) { MethodTimerSpec::Target.new }

  before do
    stub_const('MethodTimerSpec::Target', target_class)
    allow(described_class).to receive(:warn)
    described_class.install(MethodTimerSpec, silence_sql: false)
  end

  def stats_for(method_name)
    described_class.stats["Target##{method_name}"]
  end

  describe '.run' do
    it 'counts every call and returns the block value' do
      result = described_class.run { Array.new(20_000) { target.counted }.size }

      expect(result).to eq(20_000)
      expect(stats_for(:counted)[:calls]).to eq(20_000)
    end

    it 'accumulates calls and time across repeated nested calls' do
      described_class.run { 5.times { target.outer } }

      expect(stats_for(:outer)[:calls]).to eq(5)
      expect(stats_for(:inner)[:calls]).to eq(5)
      expect(stats_for(:inner)[:total_t]).to be >= 0.01
      expect(stats_for(:outer)[:total_t]).to be >= stats_for(:inner)[:total_t]
      expect(stats_for(:outer)[:self_t]).to be < 0.005
    end

    it 'excludes instrumented callees from self time' do
      described_class.run { target.outer }

      expect(stats_for(:outer)[:self_t]).to be < stats_for(:inner)[:total_t]
      expect(stats_for(:outer)[:total_t]).to be >= stats_for(:inner)[:total_t]
    end

    it 'charges GC pauses to the method that triggered them, not its callers' do
      described_class.run { target.caller_of_collect }

      expect(stats_for(:collect)[:gc_t]).to be > 0
      expect(stats_for(:caller_of_collect)[:gc_t]).to eq(0)
    end

    it 'charges SQL to the method that ran it, skipping cached queries' do
      described_class.run do
        target.query
        target.query(cached: true)
      end

      expect(stats_for(:query)).to include(calls: 2, sql_calls: 1)
    end

    it 'records only calls made by the thread running the block' do
      described_class.run do
        Thread.new { 3.times { target.outer } }.join
        target.outer
      end

      expect(stats_for(:outer)[:calls]).to eq(1)
    end

    it 'samples memory with rss: true' do
      allow(described_class).to receive(:warn).and_call_original

      expect { described_class.run(rss: true) { target.outer } }.to output(/RSS peak/).to_stderr
    end
  end

  describe '.bench' do
    it 'reports the highest RSS sampled during the block, not the final reading' do
      allow(described_class).to receive_messages(start_rss_sampler: :sampler)
      allow(described_class).to receive(:current_rss).and_return(100, 200)
      allow(described_class).to receive(:stop_rss_sampler).with(:sampler).and_return(500)

      described_class.bench(rss: true) { nil }

      expect(described_class.instance_variable_get(:@rss_peak)).to eq(500)
      expect(described_class.instance_variable_get(:@rss_end)).to eq(200)
    end

    it 'prints wall time, GC, SQL and allocations and returns the block value' do
      allow(described_class).to receive(:warn).and_call_original
      result = nil

      expect { result = described_class.bench { target.query } }
        .to output(/wall.*\nGC.*\nSQL .*\(1 queries\)\nallocations/m).to_stderr
      expect(result).to eq(:queried)
    end
  end
end
