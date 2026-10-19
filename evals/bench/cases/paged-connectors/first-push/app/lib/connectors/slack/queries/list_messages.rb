module Connectors
  module Slack
    module Queries
      class ListMessages
        REPLY_LIMIT = 500

        Input = Dry::Schema.Params do
          required(:account_id).filled(:string)
          required(:channel).filled(:string)
          optional(:since).maybe(:time)
          optional(:since_days).maybe(:integer, gt?: 0)
          optional(:cursor).maybe(:string)
          optional(:pages).maybe(:integer, gt?: 0, lteq?: Connectors::Services::PageLimit::MAX_PAGES)
          optional(:limit).filled(:integer, gt?: 0, lteq?: 200)
        end

        Result = Struct.new(:items, :next_cursor, :pages_fetched, :since, keyword_init: true)

        def self.call(**params)
          new(params).call
        end

        def initialize(params)
          @input = Input.call(params)
        end

        def call
          raise Connectors::InvalidInput, input.errors.to_h unless input.success?

          since = Connectors::Services::LookBack.call(account: account, override: input[:since], since_days: input[:since_days])
          cursor = input[:cursor]
          items = []

          pages = Connectors::Services::PageLimit.call(max: max_pages) do
            page = client.messages(channel: input[:channel], oldest: since, cursor: cursor, limit: limit)
            page.items.reject { |raw| raw["subtype"] }.each do |raw|
              items << normalize(raw)
              items.concat(replies_for(raw, since)) if raw["reply_count"].to_i.positive?
            end
            cursor = page.next_cursor
            cursor.present?
          end

          Result.new(items: items, next_cursor: cursor, pages_fetched: pages, since: since)
        end

        private

        attr_reader :input

        def account
          @account ||= ConnectorAccount.for_provider("slack").find(input[:account_id])
        end

        def client
          @client ||= Connectors::Slack::Client.new(account)
        end

        def limit
          input[:limit] || Connectors::Slack::Client::LIMIT
        end

        def max_pages
          input[:pages] || Connectors::Services::PageLimit.max_pages
        end

        def replies_for(parent, since)
          replies = client.replies(channel: input[:channel], ts: parent.fetch("ts"), limit: REPLY_LIMIT)
          replies
            .reject { |raw| raw["ts"] == parent["ts"] || raw["subtype"] || Time.zone.at(raw.fetch("ts").to_f) < since }
            .map { |raw| normalize(raw) }
        end

        def normalize(raw)
          ts = raw.fetch("ts")
          {
            external_id: "#{input[:channel]}:#{ts}",
            kind: "message",
            title: raw.fetch("text").to_s.truncate(200),
            url: client.permalink(channel: input[:channel], ts: ts),
            external_updated_at: Time.zone.at(ts.to_f),
            payload: raw.slice("user", "thread_ts", "reply_count")
          }
        end
      end
    end
  end
end
