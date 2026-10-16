module Connectors
  module Services
    class LookBack
      DEFAULT_WINDOW = 14.days
      OVERLAP = 5.minutes

      def self.call(account:, override: nil, now: Time.current)
        new(account: account, override: override, now: now).call
      end

      def initialize(account:, override:, now:)
        @account = account
        @override = override
        @now = now
      end

      def call
        return override if override

        floor = now - DEFAULT_WINDOW
        return floor if account.last_synced_at.nil?

        [account.last_synced_at - OVERLAP, floor].max
      end

      private

      attr_reader :account, :override, :now
    end
  end
end
