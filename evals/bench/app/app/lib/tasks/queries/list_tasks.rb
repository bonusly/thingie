module Tasks
  module Queries
    class ListTasks
      FILTERS = %i[state list_id assignee_id label_ids due_before due_after q].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(company:, user:, filters: {})
        @company = company
        @user = user
        @filters = filters.to_h.symbolize_keys.slice(*FILTERS)
      end

      def call
        apply_filters(base_scope).ordered
      end

      private

      attr_reader :company, :user, :filters

      def base_scope
        visible_list_ids = List.for_company(company).visible_to(user).pluck(:id)
        Task.for_company(company).in(list_id: visible_list_ids)
      end

      def apply_filters(scope)
        scope = scope.where(state: filters[:state]) if filters[:state].present?
        scope = scope.where(list_id: filters[:list_id]) if filters[:list_id].present?
        scope = scope.where(assignee_ids: filters[:assignee_id]) if filters[:assignee_id].present?
        scope = scope.in(label_ids: Array(filters[:label_ids])) if filters[:label_ids].present?
        scope = scope.where(:due_on.lte => filters[:due_before]) if filters[:due_before].present?
        scope = scope.where(:due_on.gte => filters[:due_after]) if filters[:due_after].present?
        scope = scope.where(title: /#{Regexp.escape(filters[:q])}/i) if filters[:q].present?
        scope
      end
    end
  end
end
