module Search
  module Tools
    class SlackSearch < Base
      def self.parameters
        super.merge(channel: { type: "string", description: I18n.t("search.tools.params.channel") })
      end

      private

      def query(account)
        channel = options[:channel].presence || Array(account.setting("channels")).first
        raise Connectors::InvalidInput, { channel: ["is missing"] } if channel.blank?

        Connectors::Slack::Queries::ListMessages.call(account_id: account.id.to_s, channel: channel, **query_params)
      end
    end
  end
end
