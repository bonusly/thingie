module DraftTasks
  module Commands
    class Create
      PERMITTED = %i[title description note points due_on scheduled_for visibility assignee_ids label_ids].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(company:, author:, list:, attrs:)
        @company = company
        @author = author
        @list = list
        @attrs = attrs.to_h.symbolize_keys.slice(*PERMITTED)
      end

      def call
        return Result.failure("list does not belong to this company") unless list.company_id == company.id
        return Result.failure("list is archived") if list.archived?

        draft = DraftTask.new(attrs.merge(company: company, author: author, list: list))
        return Result.failure(draft.errors.full_messages) unless draft.save

        Result.success(draft)
      end

      private

      attr_reader :company, :author, :list, :attrs
    end
  end
end
