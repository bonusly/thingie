module Connectors
  module Services
    class Registry
      QUERIES = {
        "github" => [Connectors::Github::Queries::ListIssues, Connectors::Github::Queries::ListPullRequests],
        "slack" => [Connectors::Slack::Queries::ListMessages],
        "linear" => [Connectors::Linear::Queries::ListIssues, Connectors::Linear::Queries::ListProjects]
      }.freeze

      CLIENTS = {
        "github" => Connectors::Github::Client,
        "slack" => Connectors::Slack::Client,
        "linear" => Connectors::Linear::Client
      }.freeze

      def self.queries_for(provider)
        QUERIES.fetch(provider) { raise Connectors::UnknownProvider, provider }
      end

      def self.client_for(account)
        CLIENTS.fetch(account.provider) { raise Connectors::UnknownProvider, account.provider }.new(account)
      end

      def self.providers
        QUERIES.keys
      end
    end
  end
end
