module Connectors
  module Slack
    module Queries
      class ListMessages
        Input = Dry::Schema.Params do
          required(:account_id).filled(:string)
          required(:channel).filled(:string)
          optional(:since).maybe(:time)
          optional(:cursor).maybe(:string)
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

          since = Connectors::Services::LookBack.call(account: account, override: input[:since])
          cursor = input[:cursor]
          items = []

          pages = Connectors::Services::PageLimit.call do
            page = client.messages(channel: input[:channel], oldest: since, cursor: cursor, limit: limit)
            items.concat(page.items.reject { |raw| raw["subtype"] }.map { |raw| normalize(raw) })
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
