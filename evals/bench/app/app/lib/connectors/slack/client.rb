module Connectors
  module Slack
    class Client
      LIMIT = 100

      def initialize(account)
        @account = account
      end

      def messages(channel:, oldest:, cursor: nil, limit: LIMIT)
        body = post("conversations.history", channel: channel, oldest: oldest.to_f.to_s, cursor: cursor, limit: limit)
        Connectors::Page.new(items: body.fetch("messages", []), next_cursor: next_cursor(body))
      end

      def channels(cursor: nil, limit: LIMIT)
        body = post("conversations.list", cursor: cursor, limit: limit, exclude_archived: true)
        Connectors::Page.new(items: body.fetch("channels", []), next_cursor: next_cursor(body))
      end

      def permalink(channel:, ts:)
        post("chat.getPermalink", channel: channel, message_ts: ts).fetch("permalink")
      end

      private

      attr_reader :account

      def post(method, params)
        response = connection.post(method, params.compact)
        body = response.body
        raise Connectors::Unauthorized, "slack" if body["error"] == "invalid_auth"
        raise Connectors::RateLimited.new("slack", retry_after: response.headers["retry-after"]) if response.status == 429
        raise Connectors::Error, body["error"] unless body["ok"]

        body
      end

      def next_cursor(body)
        body.dig("response_metadata", "next_cursor").presence
      end

      def connection
        @connection ||= Faraday.new(url: Rails.application.config.x.connectors.slack[:api_base]) do |conn|
          conn.request :url_encoded
          conn.response :json, content_type: /\bjson$/
          conn.headers["Authorization"] = "Bearer #{account.access_token}"
        end
      end
    end
  end
end
