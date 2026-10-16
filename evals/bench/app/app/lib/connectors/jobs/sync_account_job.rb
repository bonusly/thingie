module Connectors
  module Jobs
    class SyncAccountJob
      include Sidekiq::Job

      sidekiq_options queue: :connectors, retry: 3

      def perform(account_id)
        account = ConnectorAccount.where(id: account_id).first
        return if account.nil? || !account.connected?

        last_cursor = nil
        Connectors::Services::Registry.queries_for(account.provider).each do |query|
          scopes_for(account).each do |scope|
            result = query.call(account_id: account.id.to_s, cursor: account.cursor, **scope)
            Connectors::Commands::ImportItems.call(account: account, items: result.items)
            last_cursor = result.next_cursor
          end
        end
        account.touch_synced!(cursor: last_cursor)
      rescue Connectors::RateLimited => e
        account.record_error!(e.message)
        self.class.perform_in((e.retry_after || 60).to_i, account_id)
      rescue Connectors::Unauthorized => e
        account.record_error!(e.message)
        account.pause!
      end

      private

      def scopes_for(account)
        return [{}] unless account.provider == "slack"

        Array(account.setting("channels")).map { |channel| { channel: channel } }
      end
    end
  end
end
