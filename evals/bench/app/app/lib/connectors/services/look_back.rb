module Connectors
  module Services
    class LookBack
      DEFAULT_WINDOW = 14.days
      MAX_SINCE_DAYS = 365
      OVERLAP = 5.minutes

      def self.call(account:, override: nil, since_days: nil, now: Time.current)
        new(account: account, override: override, since_days: since_days, now: now).call
      end

      def self.floor(now: Time.current)
        now - DEFAULT_WINDOW
      end

      def initialize(account:, override:, since_days:, now:)
        @account = account
        @override = override
        @since_days = since_days
        @now = now
      end

      def call
        return override if override
        return now - since_days.to_i.clamp(1, MAX_SINCE_DAYS).days if since_days

        floor = self.class.floor(now: now)
        return floor if account.last_synced_at.nil?

        [account.last_synced_at - OVERLAP, floor].max
      end

      private

      attr_reader :account, :override, :since_days, :now
    end
  end
end
