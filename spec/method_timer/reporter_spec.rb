# frozen_string_literal: true

RSpec.describe MethodTimer::Reporter do
  subject(:timer) { MethodTimer }

  let(:long_name) { "long_#{'x' * 80}" }

  before do
    name = long_name
    stub_const('MethodTimerSpec::Reported', Class.new do
      define_method(name) { fast }
      define_method(:fast) { nil }
    end)
    allow(timer).to receive(:warn)
    timer.install(MethodTimerSpec::Reported, silence_sql: false)
    timer.run { MethodTimerSpec::Reported.new.public_send(long_name) }
    allow(timer).to receive(:warn).and_call_original
  end

  describe '.report' do
    it 'widens the name column to the longest label' do
      expect { timer.report(threshold: 0) }.to output(/^Reported##{long_name} +\d/).to_stderr
    end

    it 'hides methods below the threshold' do
      expect { timer.report(threshold: 1) }.not_to output(/Reported#fast/).to_stderr
    end

    it 'prints the totals, GC and estimated instrumentation overhead' do
      expect { timer.report }.to output(
        /TOTAL \(wall time of run block\).*of which GC.*instrumentation overhead \(estimated\).*\(2 calls x/m
      ).to_stderr
    end
  end

  describe 'byte formatting' do
    it 'picks a readable unit' do
      expect(timer.send(:format_bytes, 512)).to eq('512.0B')
      expect(timer.send(:format_bytes, 3 * 1024 * 1024)).to eq('3.0MB')
      expect(timer.send(:format_bytes, 5 * (1024**4))).to eq('5120.0GB')
      expect(timer.send(:format_bytes, nil)).to eq('-')
    end
  end
end
