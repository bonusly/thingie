module Search
  module Tools
    class LinearSearch < Base
      def self.parameters
        super.merge(team_key: { type: "string", description: I18n.t("search.tools.params.team_key") })
      end

      private

      def query(account)
        Connectors::Linear::Queries::ListIssues.call(
          account_id: account.id.to_s, team_key: options[:team_key].presence, **query_params
        )
      end
    end
  end
end
