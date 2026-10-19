module Connectors
  module Commands
    class ImportAsTask
      def self.call(item:, actor:, list:)
        new(item: item, actor: actor, list: list).call
      end

      def initialize(item:, actor:, list:)
        @item = item
        @actor = actor
        @list = list
      end

      def call
        return Result.failure("item was already imported") if item.imported?
        return Result.failure("list belongs to another company") unless list.company_id == item.company_id

        result = Tasks::Commands::Create.call(
          company: item.company, author: actor, list: list,
          attrs: { title: item.title, description: item.url, external_item_id: item.id }
        )
        return result if result.failure?

        item.mark_imported!(result.value)
        result
      end

      private

      attr_reader :item, :actor, :list
    end
  end
end
