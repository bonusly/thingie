module DraftTasks
  module Commands
    class Create
      PERMITTED = %i[title description note points due_on scheduled_for visibility assignee_ids label_ids].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(company:, author:, attrs:)
        @company = company
        @author = author
        @attrs = attrs.to_h.symbolize_keys.slice(*PERMITTED)
      end

      def call
        draft = DraftTask.new(attrs.merge(company: company, author: author))
        return Result.failure(draft.errors.full_messages) unless draft.save

        Result.success(draft)
      end

      private

      attr_reader :company, :author, :attrs
    end
  end
end
