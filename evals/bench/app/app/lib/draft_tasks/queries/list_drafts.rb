module DraftTasks
  module Queries
    class ListDrafts
      STATES = DraftTask.aasm.states.map { |state| state.name.to_s }.freeze

      def self.call(company:, author:, state: nil, list_id: nil)
        new(company: company, author: author, state: state, list_id: list_id).call
      end

      def initialize(company:, author:, state:, list_id:)
        @company = company
        @author = author
        @state = state.presence
        @list_id = list_id.presence
      end

      def call
        scope = DraftTask.for_company(company).by_author(author)
        scope = scope.where(state: state) if state && STATES.include?(state)
        scope = scope.where(list_id: list_id) if list_id
        scope.order(scheduled_for: :asc, created_at: :desc)
      end

      private

      attr_reader :company, :author, :state, :list_id
    end
  end
end
