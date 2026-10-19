module Admin
  module Commands
    class SuspendCompany
      def self.call(company:, actor:, reason:)
        new(company: company, actor: actor, reason: reason).call
      end

      def initialize(company:, actor:, reason:)
        @company = company
        @actor = actor
        @reason = reason
      end

      def call
        return Result.failure(Admin::NotStaff.new(actor)) unless actor&.staff?
        return Result.failure(Admin::AlreadySuspended.new(company)) unless company.active?

        company.suspend!
        company.connector_accounts.connected.each(&:pause!)
        company.api_keys.active.each(&:revoke!)
        AuditLog.record!(company: company, actor: actor, action: "company.suspended", target: company, details: { reason: reason })
        Result.success(company)
      end

      private

      attr_reader :company, :actor, :reason
    end
  end
end
