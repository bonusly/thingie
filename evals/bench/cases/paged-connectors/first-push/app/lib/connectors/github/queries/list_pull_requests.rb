module Connectors
  module Github
    module Queries
      class ListPullRequests
        Input = Dry::Schema.Params do
          required(:account_id).filled(:string)
          optional(:since).maybe(:time)
          optional(:since_days).maybe(:integer, gt?: 0)
          optional(:cursor).maybe(:string)
          optional(:pages).maybe(:integer, gt?: 0, lteq?: Connectors::Services::PageLimit::MAX_PAGES)
          optional(:per_page).filled(:integer, gt?: 0, lteq?: 100)
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
            page = client.pull_requests(since: since, cursor: cursor, per_page: per_page)
            items.concat(page.items.map { |raw| normalize(raw) })
            cursor = page.next_cursor&.to_s
            cursor.present?
          end

          Result.new(items: items, next_cursor: cursor, pages_fetched: pages, since: since)
        end

        private

        attr_reader :input

        def account
          @account ||= ConnectorAccount.for_provider("github").find(input[:account_id])
        end

        def client
          @client ||= Connectors::Github::Client.new(account)
        end

        def per_page
          input[:per_page] || Connectors::Github::Client::PER_PAGE
        end

        def max_pages
          input[:pages] || Connectors::Services::PageLimit.max_pages
        end

        def normalize(raw)
          {
            external_id: raw.fetch("id").to_s,
            kind: "pull_request",
            title: raw.fetch("title"),
            url: raw.fetch("html_url"),
            external_updated_at: Time.iso8601(raw.fetch("updated_at")),
            payload: raw.slice("number", "state", "draft", "repository_url")
          }
        end
      end
    end
  end
end
