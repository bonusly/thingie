module Search
  module Queries
    class ConnectedSearch
      Result = Struct.new(:items, :next_cursor, :truncated, :skipped, keyword_init: true)

      def self.call(**)
        new(**).call
      end

      def initialize(company:, user:, q: nil, since_days: nil, cursor: nil, providers: nil)
        @company = company
        @user = user
        @q = q
        @since_days = since_days
        @cursor = cursor.presence
        @providers = providers
      end

      def call
        skipped = []
        results = Search::Tools::Registry.for(providers).filter_map do |tool|
          tool.call(company: company, user: user, q: q, since_days: since_days, cursor: cursor)
        rescue Search::NotConnected => e
          skipped << e.provider
          nil
        end

        next_cursor = results.map(&:next_cursor).compact.last
        Result.new(items: ordered(results), next_cursor: next_cursor, truncated: next_cursor.present?, skipped: skipped)
      end

      private

      attr_reader :company, :user, :q, :since_days, :cursor, :providers

      def ordered(results)
        results.flat_map { |result| result.items.map { |item| item.merge(provider: result.provider) } }
               .sort_by { |item| item[:external_updated_at] }
               .reverse
      end
    end
  end
end
