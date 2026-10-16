module Admin
  module Commands
    class ChangeRole
      def self.call(membership:, actor:, role:)
        new(membership: membership, actor: actor, role: role).call
      end

      def initialize(membership:, actor:, role:)
        @membership = membership
        @actor = actor
        @role = role.to_s
      end

      def call
        return Result.failure("unknown role #{role}") unless Membership::ROLES.include?(role)
        return Result.failure("not allowed") unless allowed?
        return Result.failure("cannot demote the last admin") if demoting_last_admin?

        membership.update!(role: role)
        AuditLog.record!(company: membership.company, actor: actor, action: "membership.role_changed", target: membership, details: { role: role })
        Result.success(membership)
      end

      private

      attr_reader :membership, :actor, :role

      def allowed?
        actor.staff? || actor.admin_of?(membership.company)
      end

      def demoting_last_admin?
        role == "member" && membership.admin? && membership.company.memberships.active.admins.count == 1
      end
    end
  end
end
