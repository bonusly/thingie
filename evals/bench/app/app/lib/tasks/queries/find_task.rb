module Tasks
  module Queries
    class FindTask
      def self.call(company:, id:)
        new(company: company, id: id).call
      end

      def initialize(company:, id:)
        @company = company
        @id = id
      end

      def call
        task = Task.for_company(company).where(id: id).first
        raise Tasks::NotFound, id if task.nil?

        task
      end

      private

      attr_reader :company, :id
    end
  end
end
