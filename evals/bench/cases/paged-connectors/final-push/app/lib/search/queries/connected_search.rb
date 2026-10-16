module Search
  module Queries
    class ConnectedSearch
      Result = Struct.new(:items, :next_cursors, :truncated, :skipped, keyword_init: true)

      def self.call(**)
        new(**).call
      end

      def initialize(company:, user:, q: nil, since_days: nil, cursors: {}, providers: nil)
        @company = company
        @user = user
        @q = q
        @since_days = since_days
        @cursors = (cursors || {}).to_h.transform_keys(&:to_s)
        @providers = providers
      end

      def call
        skipped = []
        results = Search::Tools::Registry.for(providers).filter_map do |tool|
          tool.call(company: company, user: user, q: q, since_days: since_days, cursor: cursors[tool.provider])
        rescue Search::NotConnected => e
          skipped << e.provider
          nil
        end

        next_cursors = results.each_with_object({}) { |result, acc| acc[result.provider] = result.next_cursor if result.next_cursor }
        Result.new(items: ordered(results), next_cursors: next_cursors, truncated: next_cursors.any?, skipped: skipped)
      end

      private

      attr_reader :company, :user, :q, :since_days, :cursors, :providers

      def ordered(results)
        results.flat_map { |result| result.items.map { |item| item.merge(provider: result.provider) } }
               .sort_by { |item| item[:external_updated_at] }
               .reverse
      end
    end
  end
end
