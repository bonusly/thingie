module Lists
  module Commands
    class Update
      PERMITTED = %i[name description visibility position member_ids].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(list:, actor:, attrs:)
        @list = list
        @actor = actor
        @attrs = attrs.to_h.symbolize_keys.slice(*PERMITTED)
      end

      def call
        return Result.failure(Lists::Archived.new(list)) if list.archived?

        list.assign_attributes(attrs)
        changed = list.changes.keys
        return Result.success(list) if changed.empty?
        return Result.failure(list.errors.full_messages) unless list.save

        AuditLog.record!(company: list.company, actor: actor, action: "list.updated", target: list, details: { fields: changed })
        Result.success(list)
      end

      private

      attr_reader :list, :actor, :attrs
    end
  end
end
