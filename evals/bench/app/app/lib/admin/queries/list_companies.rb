module Admin
  module Queries
    class ListCompanies
      def self.call(filters: {}, page: 1, per_page: 50)
        new(filters: filters, page: page, per_page: per_page).call
      end

      def initialize(filters:, page:, per_page:)
        @filters = filters.to_h.symbolize_keys
        @page = [page.to_i, 1].max
        @per_page = per_page.to_i.clamp(1, 200)
      end

      def call
        scope = Company.all
        scope = scope.where(plan: filters[:plan]) if filters[:plan].present?
        scope = scope.suspended if filters[:suspended] == true
        scope = scope.active if filters[:suspended] == false
        scope = scope.any_of({ name: /#{Regexp.escape(filters[:q])}/i }, { slug: filters[:q] }) if filters[:q].present?
        scope.order(created_at: :desc).skip((page - 1) * per_page).limit(per_page)
      end

      private

      attr_reader :filters, :page, :per_page
    end
  end
end
