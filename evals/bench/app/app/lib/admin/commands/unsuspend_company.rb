module Admin
  module Commands
    class UnsuspendCompany
      def self.call(company:, actor:)
        new(company: company, actor: actor).call
      end

      def initialize(company:, actor:)
        @company = company
        @actor = actor
      end

      def call
        return Result.failure(Admin::NotStaff.new(actor)) unless actor&.staff?
        return Result.success(company) if company.active?

        company.unsuspend!
        company.connector_accounts.where(state: "paused").each(&:resume!)
        AuditLog.record!(company: company, actor: actor, action: "company.unsuspended", target: company)
        Result.success(company)
      end

      private

      attr_reader :company, :actor
    end
  end
end
