# frozen_string_literal: true

RSpec.describe MethodTimer::Instrumenter do
  subject(:timer) { MethodTimer }

  let(:target_class) do
    Class.new do
      def call(value, key:, &block) = block ? yield(value, key) : [value, key]

      def assign=(value)
        @value = value
      end

      def visible_helper = hidden_helper

      private

      def hidden_helper = :hidden
    end
  end
  let(:target) { MethodTimerSpec::Target.new }

  before do
    stub_const('MethodTimerSpec::Target', target_class)
    allow(timer).to receive(:warn)
    timer.install(MethodTimerSpec, silence_sql: false)
  end

  describe '.install' do
    it 'forwards positional, keyword and block arguments' do
      expect(target.call(1, key: 2)).to eq([1, 2])
      expect(target.call(1, key: 2) { |value, key| value + key }).to eq(3)
    end

    it 'keeps private methods private' do
      expect { target.hidden_helper }.to raise_error(NoMethodError)
      expect(target.visible_helper).to eq(:hidden)
    end

    it 'adds no allocations of its own to an instrumented call' do
      target.assign = 1
      allocations_before = GC.stat(:total_allocated_objects)
      1_000.times { target.assign = 1 }

      expect(GC.stat(:total_allocated_objects) - allocations_before).to be < 10
    end

    it 'strips the namespace shared by all instrumented classes from labels' do
      timer.run { target.call(1, key: 2) }

      expect(timer.stats.keys).to include('Target#call')
    end

    it 'keeps the full namespace with strip_root: false' do
      stub_const('MethodTimerSpec::Full', Class.new { def full = :full })
      timer.install(MethodTimerSpec::Full, silence_sql: false, strip_root: false)
      timer.run { MethodTimerSpec::Full.new.full }

      expect(timer.stats.keys).to include('MethodTimerSpec::Full#full')
    end

    it 'reports methods of directly included modules under the module name' do
      stub_const('MethodTimerSpec::Mixin', Module.new { def mixed_in = :mixed })
      stub_const('MethodTimerSpec::WithMixin', Class.new { include MethodTimerSpec::Mixin })
      timer.install(MethodTimerSpec::WithMixin, silence_sql: false, strip_root: false)
      timer.run { MethodTimerSpec::WithMixin.new.mixed_in }

      expect(timer.stats).to include('MethodTimerSpec::Mixin#mixed_in')
    end

    it 'keeps calibration out of the stats, across repeated installs' do
      timer.install(MethodTimerSpec, silence_sql: false)

      expect(timer.stats).to be_empty
      expect(MethodTimer::Recorder::NAMES.count('MethodTimer#calibration')).to eq(1)
    end

    it 'measures a positive per-call overhead' do
      expect(timer.send(:calibrate)).to be > 0
    end
  end

  describe '.uninstall' do
    it 'removes the wrappers so calls are no longer timed' do
      expect(timer.uninstall).to eq(1)
      timer.run { target.call(1, key: 2) }

      expect(target.method(:call).owner).to eq(MethodTimerSpec::Target)
      expect(timer.stats).to be_empty
    end

    it 'keeps instrumented methods working, private ones included' do
      timer.uninstall

      expect(target.call(1, key: 2)).to eq([1, 2])
      expect(target.visible_helper).to eq(:hidden)
      expect { target.hidden_helper }.to raise_error(NoMethodError)
    end

    it 'allows installing again from scratch' do
      timer.uninstall
      timer.install(MethodTimerSpec, silence_sql: false)
      timer.run { target.call(1, key: 2) }

      expect(timer.stats['Target#call'][:calls]).to eq(1)
    end
  end

  describe '.common_namespace' do
    it 'returns the longest shared namespace' do
      expect(timer.common_namespace(%w[A::B::C A::B::D::E])).to eq('A::B')
    end

    it 'always leaves the leaf segment' do
      expect(timer.common_namespace(%w[A::B])).to eq('A')
      expect(timer.common_namespace(%w[A::B A::B])).to eq('A')
    end

    it 'returns an empty string when nothing is shared' do
      expect(timer.common_namespace(%w[A::B C::D])).to eq('')
      expect(timer.common_namespace([])).to eq('')
    end
  end
end
