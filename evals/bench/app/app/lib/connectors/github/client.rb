module Connectors
  module Github
    class Client
      PER_PAGE = 50

      def initialize(account)
        @account = account
      end

      def issues(since:, cursor: nil, per_page: PER_PAGE, state: "all")
        get("/issues", filter: "all", state: state, since: since.iso8601, page: cursor || 1, per_page: per_page)
      end

      def pull_requests(since:, cursor: nil, per_page: PER_PAGE)
        query = "is:pr involves:@me updated:>=#{since.to_date.iso8601}"
        page = get("/search/issues", q: query, page: cursor || 1, per_page: per_page, sort: "updated")
        Connectors::Page.new(items: page.items.fetch("items", page.items), next_cursor: page.next_cursor)
      end

      private

      attr_reader :account

      def get(path, params)
        response = connection.get(path, params)
        raise Connectors::Unauthorized, "github" if response.status == 401
        raise Connectors::RateLimited.new("github", retry_after: response.headers["retry-after"]) if response.status == 429

        Connectors::Page.new(items: response.body, next_cursor: next_page_from(response.headers["link"]))
      end

      def next_page_from(link_header)
        return nil if link_header.blank?

        match = link_header.match(/[?&]page=(\d+)[^>]*>;\s*rel="next"/)
        match && match[1].to_i
      end

      def connection
        @connection ||= Faraday.new(url: Rails.application.config.x.connectors.github[:api_base]) do |conn|
          conn.request :json
          conn.response :json, content_type: /\bjson$/
          conn.headers["Authorization"] = "Bearer #{account.access_token}"
          conn.headers["Accept"] = "application/vnd.github+json"
        end
      end
    end
  end
end
