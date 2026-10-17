# frozen_string_literal: true

module MethodTimer
  # SQL tracking through ActiveRecord's `sql.active_record` notifications; a no-op without ActiveSupport.
  module Sql
    private

    def subscribe_sql
      return unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.subscribe('sql.active_record') do |_, start, finish, _, payload|
        yield(start, finish) unless payload[:cached] || payload[:name] == 'SCHEMA'
      end
    end

    def unsubscribe_sql(subscriber)
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
