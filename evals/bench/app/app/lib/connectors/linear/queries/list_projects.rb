module Connectors
  module Linear
    module Queries
      class ListProjects
        Input = Dry::Schema.Params do
          required(:account_id).filled(:string)
          optional(:since).maybe(:time)
          optional(:cursor).maybe(:string)
          optional(:first).filled(:integer, gt?: 0, lteq?: 250)
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
            page = client.projects(after: cursor, first: input[:first] || Connectors::Linear::Client::FIRST)
            fresh = page.items.select { |raw| Time.iso8601(raw.fetch("updatedAt")) >= since }
            items.concat(fresh.map { |raw| normalize(raw) })
            cursor = page.next_cursor
            cursor.present? && fresh.size == page.size
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

        def normalize(raw)
          {
            external_id: raw.fetch("id"),
            kind: "project",
            title: raw.fetch("name"),
            url: raw.fetch("url"),
            external_updated_at: Time.iso8601(raw.fetch("updatedAt")),
            payload: raw.slice("state", "progress")
          }
        end
      end
    end
  end
end
