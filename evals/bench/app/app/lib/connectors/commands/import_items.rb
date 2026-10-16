module Connectors
  module Commands
    class ImportItems
      Summary = Struct.new(:created, :updated, :skipped, keyword_init: true)

      def self.call(account:, items:)
        new(account: account, items: items).call
      end

      def initialize(account:, items:)
        @account = account
        @items = items
      end

      def call
        summary = Summary.new(created: 0, updated: 0, skipped: 0)

        items.each do |attrs|
          item = ExternalItem.for_company(account.company).for_provider(account.provider)
            .find_or_initialize_by(external_id: attrs.fetch(:external_id))
          next summary.skipped += 1 if unchanged?(item, attrs)

          item.new_record? ? summary.created += 1 : summary.updated += 1
          item.update!(attrs.merge(connector_account: account))
        end

        Result.success(summary)
      end

      private

      attr_reader :account, :items

      def unchanged?(item, attrs)
        item.persisted? && item.external_updated_at.present? && item.external_updated_at >= attrs.fetch(:external_updated_at)
      end
    end
  end
end
