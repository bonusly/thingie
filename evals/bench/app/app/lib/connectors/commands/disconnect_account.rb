module Connectors
  module Commands
    class DisconnectAccount
      def self.call(account:, actor:)
        new(account: account, actor: actor).call
      end

      def initialize(account:, actor:)
        @account = account
        @actor = actor
      end

      def call
        return Result.failure("account is already disconnected") unless account.may_disconnect?

        account.disconnect!
        account.external_items.unimported.delete_all
        AuditLog.record!(company: account.company, actor: actor, action: "connector.disconnected", target: account)
        Result.success(account)
      end

      private

      attr_reader :account, :actor
    end
  end
end
