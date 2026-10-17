# frozen_string_literal: true

RSpec.describe MethodTimer::Memory do
  subject(:timer) { MethodTimer }

  it 'reads the current process RSS in bytes' do
    expect(timer.send(:current_rss)).to be > 1024 * 1024
  end

  it 'samples the peak RSS from a child process and stops it' do
    stub_const('MethodTimer::Memory::RSS_INTERVAL', 0.05)
    sampler = timer.send(:start_rss_sampler)
    sleep(0.2)
    peak = timer.send(:stop_rss_sampler, sampler)

    expect(peak).to be > 1024 * 1024
    expect { Process.kill(0, sampler.first) }.to raise_error(Errno::ESRCH)
  end

  it 'allocates nothing in this process while sampling' do
    stub_const('MethodTimer::Memory::RSS_INTERVAL', 0.01)
    sampler = timer.send(:start_rss_sampler)
    allocations_before = GC.stat(:total_allocated_objects)
    sleep(0.2)
    allocations = GC.stat(:total_allocated_objects) - allocations_before
    timer.send(:stop_rss_sampler, sampler)

    expect(allocations).to be < 5
  end

  it 'returns nil when there is no sampler' do
    expect(timer.send(:stop_rss_sampler, nil)).to be_nil
  end
end
