module Lists
  module Queries
    class FindList
      def self.call(company:, id:)
        new(company: company, id: id).call
      end

      def initialize(company:, id:)
        @company = company
        @id = id
      end

      def call
        list = List.for_company(company).any_of({ id: id }, { slug: id.to_s }).first
        raise Lists::NotFound, id if list.nil?

        list
      end

      private

      attr_reader :company, :id
    end
  end
end
