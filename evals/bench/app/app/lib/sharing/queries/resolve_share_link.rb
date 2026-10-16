module Sharing
  module Queries
    class ResolveShareLink
      def self.call(token:, now: Time.current)
        new(token: token, now: now).call
      end

      def initialize(token:, now:)
        @token = token.to_s
        @now = now
      end

      def call
        link = ShareLink.find_active(token, now: now)
        raise Sharing::NotFound if link.nil? || link.list.archived? || !link.company.active?

        link
      end

      private

      attr_reader :token, :now
    end
  end
end
