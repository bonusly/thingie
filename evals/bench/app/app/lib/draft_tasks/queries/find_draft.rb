module DraftTasks
  module Queries
    class FindDraft
      def self.call(company:, id:)
        new(company: company, id: id).call
      end

      def initialize(company:, id:)
        @company = company
        @id = id
      end

      def call
        draft = DraftTask.for_company(company).where(id: id).first
        raise DraftTasks::NotFound, id if draft.nil?

        draft
      end

      private

      attr_reader :company, :id
    end
  end
end
