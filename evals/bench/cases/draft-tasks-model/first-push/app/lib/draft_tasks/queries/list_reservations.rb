module DraftTasks
  module Queries
    class ListReservations
      DEFAULT_LIMIT = 25

      def self.call(company:, author:, limit: DEFAULT_LIMIT)
        new(company: company, author: author, limit: limit).call
      end

      def initialize(company:, author:, limit:)
        @company = company
        @author = author
        @limit = limit
      end

      def call
        DraftTask.for_company(company).by_author(author).reserving.order(ready_at: :desc).limit(limit)
      end

      private

      attr_reader :company, :author, :limit
    end
  end
end
