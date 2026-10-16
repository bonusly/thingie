namespace :connectors do
  desc "Sync every connected account (PROVIDER=github|slack|linear to filter)"
  task sync: :environment do
    scope = ConnectorAccount.connected
    scope = scope.for_provider(ENV["PROVIDER"]) if ENV["PROVIDER"].present?

    scope.each do |account|
      Connectors::Jobs::SyncAccountJob.perform_async(account.id.to_s)
      puts "enqueued #{account.provider} #{account.external_account_id}"
    end
  end

  desc "Disconnect accounts whose company is suspended"
  task prune: :environment do
    Company.suspended.each do |company|
      company.connector_accounts.connected.each do |account|
        Connectors::Commands::DisconnectAccount.call(account: account, actor: nil)
      end
    end
  end
end
