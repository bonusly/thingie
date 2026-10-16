module Lists
  module Commands
    class Create
      PERMITTED = %i[name description visibility position member_ids].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(company:, owner:, attrs:)
        @company = company
        @owner = owner
        @attrs = attrs.to_h.symbolize_keys.slice(*PERMITTED)
      end

      def call
        list = List.new(attrs.merge(company: company, owner: owner))
        list.member_ids = (Array(list.member_ids) + [owner.id]).uniq
        return Result.failure(list.errors.full_messages) unless list.save

        AuditLog.record!(company: company, actor: owner, action: "list.created", target: list)
        Result.success(list)
      end

      private

      attr_reader :company, :owner, :attrs
    end
  end
end
