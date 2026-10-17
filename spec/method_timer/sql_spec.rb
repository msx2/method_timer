# frozen_string_literal: true

RSpec.describe MethodTimer::Sql do
  subject(:timer) { MethodTimer }

  def instrument(**payload)
    ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT 1', name: 'Load', **payload)
  end

  it 'yields the timing of each query until unsubscribed' do
    timings = []
    subscriber = timer.send(:subscribe_sql) { |start, finish| timings << [start, finish] }
    instrument
    timer.send(:unsubscribe_sql, subscriber)
    instrument

    expect(timings.size).to eq(1)
    expect(timings.first.last).to be >= timings.first.first
  end

  it 'skips cached and schema queries' do
    timings = []
    subscriber = timer.send(:subscribe_sql) { |start, finish| timings << [start, finish] }
    instrument(cached: true)
    instrument(name: 'SCHEMA')
    timer.send(:unsubscribe_sql, subscriber)

    expect(timings).to be_empty
  end

  it 'does nothing without ActiveSupport' do
    hide_const('ActiveSupport::Notifications')

    expect(timer.send(:subscribe_sql) { raise 'not expected' }).to be_nil
    expect { timer.send(:unsubscribe_sql, nil) }.not_to raise_error
  end
end
