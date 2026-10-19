module Search
  module Tools
    class GithubSearch < Base
      KINDS = %w[issue pull_request].freeze

      def self.parameters
        super.merge(kind: { type: "string", enum: KINDS, description: I18n.t("search.tools.params.kind") })
      end

      private

      def query(account)
        query_class.call(account_id: account.id.to_s, **query_params)
      end

      def query_class
        return Connectors::Github::Queries::ListPullRequests if options[:kind].to_s == "pull_request"

        Connectors::Github::Queries::ListIssues
      end
    end
  end
end
