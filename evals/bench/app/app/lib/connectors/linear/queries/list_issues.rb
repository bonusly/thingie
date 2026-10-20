module Connectors
  module Linear
    module Queries
      class ListIssues
        Input = Dry::Schema.Params do
          required(:account_id).filled(:string)
          optional(:since).maybe(:time)
          optional(:since_days).maybe(:integer, gt?: 0)
          optional(:cursor).maybe(:string)
          optional(:pages).maybe(:integer, gt?: 0, lteq?: Connectors::Services::PageLimit::MAX_PAGES)
          optional(:first).filled(:integer, gt?: 0, lteq?: 250)
          optional(:team_key).maybe(:string)
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
            page = client.issues(updated_after: since, after: cursor, first: first, team_key: input[:team_key])
            items.concat(page.items.map { |raw| normalize(raw) })
            cursor = page.next_cursor
            cursor.present?
          end

          Result.new(items: items, next_cursor: cursor, pages_fetched: pages, since: since)
        end

        private

        attr_reader :input

        def account
          @account ||= ConnectorAccount.for_provider("linear").find(input[:account_id])
        end

        def client
          @client ||= Connectors::Linear::Client.new(account)
        end

        def first
          input[:first] || Connectors::Linear::Client::FIRST
        end

        def max_pages
          input[:pages] || Connectors::Services::PageLimit.max_pages
        end

        def normalize(raw)
          {
            external_id: raw.fetch("id"),
            kind: "issue",
            title: "#{raw.fetch('identifier')} #{raw.fetch('title')}",
            url: raw.fetch("url"),
            external_updated_at: Time.iso8601(raw.fetch("updatedAt")),
            payload: { "state" => raw.dig("state", "name"), "team" => raw.dig("team", "key") }
          }
        end
      end
    end
  end
end
