module Connectors
  module Jobs
    class SyncAccountJob
      include Sidekiq::Job

      WINDOW_DAYS = 14

      sidekiq_options queue: :connectors, retry: 5

      sidekiq_retries_exhausted do |job, error|
        account = ConnectorAccount.where(id: job["args"].first).first
        account&.record_error!("sync gave up: #{error.message}")
      end

      def perform(account_id)
        account = ConnectorAccount.where(id: account_id).first
        return if account.nil? || !account.connected?

        Connectors::Services::Registry.queries_for(account.provider).each do |query|
          scopes_for(account).each do |scope|
            result = query.call(account_id: account.id.to_s, since: updated_after, **scope)
            Connectors::Commands::ImportItems.call(account: account, items: result.items)
            logger.info("#{account.provider} #{query.name.demodulize}: #{result.items.size} items over #{result.pages_fetched} pages")
          end
        end

        account.touch_synced!
      rescue Connectors::RateLimited => e
        account.record_error!(e.message)
        self.class.perform_in((e.retry_after || 60).to_i, account_id)
      rescue Connectors::Unauthorized => e
        account.record_error!(e.message)
        account.pause!
      rescue StandardError => e
        account.record_error!(e.message)
        raise
      end

      private

      def updated_after
        (Date.today - WINDOW_DAYS).in_time_zone
      end

      def scopes_for(account)
        return [{}] unless account.provider == "slack"

        Array(account.setting("channels")).map { |channel| { channel: channel } }
      end
    end
  end
end
