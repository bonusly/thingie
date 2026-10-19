module Connectors
  module Commands
    class ConnectAccount
      def self.call(**)
        new(**).call
      end

      def initialize(company:, user:, provider:, external_account_id:, access_token:, external_account_name: nil)
        @company = company
        @user = user
        @provider = provider.to_s
        @external_account_id = external_account_id
        @external_account_name = external_account_name
        @access_token = access_token
      end

      def call
        return Result.failure(Connectors::UnknownProvider.new(provider)) unless Connectors::Services::Registry.providers.include?(provider)
        return Result.failure("user is not a member") unless user.member_of?(company)

        account = ConnectorAccount.for_company(company).for_provider(provider).find_or_initialize_by(external_account_id: external_account_id)
        account.user = user
        account.external_account_name = external_account_name
        account.access_token = access_token
        account.resume! if account.paused?
        return Result.failure(account.errors.full_messages) unless account.save

        Connectors::Jobs::SyncAccountJob.perform_async(account.id.to_s)
        Result.success(account)
      end

      private

      attr_reader :company, :user, :provider, :external_account_id, :external_account_name, :access_token
    end
  end
end
