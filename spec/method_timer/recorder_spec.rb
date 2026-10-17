# frozen_string_literal: true

RSpec.describe MethodTimer::Recorder do
  subject(:timer) { MethodTimer }

  let!(:outer_id) { timer.send(:register, 'Spec#outer') }
  let!(:inner_id) { timer.send(:register, 'Spec#inner') }

  before do
    timer.reset
    timer.instance_variable_set(:@thread, Thread.current)
  end

  after { timer.instance_variable_set(:@thread, nil) }

  def timed(id)
    timer.enter
    yield if block_given?
  ensure
    timer.leave(id)
  end

  it 'records calls and splits self time from instrumented callees' do
    timed(outer_id) { 2.times { timed(inner_id) { sleep(0.002) } } }

    outer, inner = timer.stats.values_at('Spec#outer', 'Spec#inner')
    expect(inner[:calls]).to eq(2)
    expect(inner[:total_t]).to be >= 0.004
    expect(outer[:total_t]).to be >= inner[:total_t]
    expect(outer[:self_t]).to be < 0.004
  end

  it 'charges SQL to the innermost instrumented method' do
    timed(outer_id) { timed(inner_id) { timer.send(:record_sql, 0.0, 0.5) } }

    expect(timer.stats['Spec#inner']).to include(sql_t: 0.5, sql_calls: 1)
    expect(timer.stats['Spec#outer']).to include(sql_t: 0.0, sql_calls: 0)
  end

  it 'ignores SQL outside instrumented methods' do
    timer.send(:record_sql, 0.0, 0.5)

    expect(timer.stats).to be_empty
  end

  it 'leaves methods that were never called out of stats' do
    timed(inner_id)

    expect(timer.stats.keys).to eq(['Spec#inner'])
  end

  it 'ignores calls and SQL from other threads' do
    Thread.new { timed(inner_id) { timer.send(:record_sql, 0.0, 0.5) } }.join

    expect(timer.stats).to be_empty
  end

  it 'clears stats on reset' do
    timed(inner_id)
    timer.reset

    expect(timer.stats).to be_empty
  end
end
