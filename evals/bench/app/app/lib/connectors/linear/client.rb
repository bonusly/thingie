module Connectors
  module Linear
    class Client
      FIRST = 50

      ISSUES_QUERY = <<~GRAPHQL
        query($after: String, $first: Int, $updatedAfter: DateTimeOrDuration) {
          issues(after: $after, first: $first, filter: { updatedAt: { gte: $updatedAfter } }, orderBy: updatedAt) {
            nodes { id identifier title url updatedAt state { name } team { key } }
            pageInfo { hasNextPage endCursor }
          }
        }
      GRAPHQL

      PROJECTS_QUERY = <<~GRAPHQL
        query($after: String, $first: Int) {
          projects(after: $after, first: $first) {
            nodes { id name url updatedAt state progress }
            pageInfo { hasNextPage endCursor }
          }
        }
      GRAPHQL

      def initialize(account)
        @account = account
      end

      def issues(updated_after:, after: nil, first: FIRST)
        connection_page("issues", ISSUES_QUERY, after: after, first: first, updatedAfter: updated_after.iso8601)
      end

      def projects(after: nil, first: FIRST)
        connection_page("projects", PROJECTS_QUERY, after: after, first: first)
      end

      private

      attr_reader :account

      def connection_page(field, query, variables)
        response = connection.post(nil, { query: query, variables: variables.compact })
        raise Connectors::Unauthorized, "linear" if response.status == 401
        raise Connectors::RateLimited.new("linear", retry_after: response.headers["retry-after"]) if response.status == 429

        data = response.body.fetch("data").fetch(field)
        page_info = data.fetch("pageInfo")
        Connectors::Page.new(items: data.fetch("nodes"), next_cursor: page_info["hasNextPage"] ? page_info["endCursor"] : nil)
      end

      def connection
        @connection ||= Faraday.new(url: Rails.application.config.x.connectors.linear[:api_base]) do |conn|
          conn.request :json
          conn.response :json, content_type: /\bjson$/
          conn.headers["Authorization"] = account.access_token.to_s
        end
      end
    end
  end
end
