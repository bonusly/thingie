module Search
  module Tools
    class Base
      Result = Struct.new(:provider, :items, :next_cursor, :truncated, :since, keyword_init: true) do
        def to_h
          { provider: provider, items: items, next_cursor: next_cursor, truncated: truncated, since: since&.iso8601 }
        end
      end

      def self.provider
        name.demodulize.delete_suffix("Search").downcase
      end

      def self.description
        I18n.t("search.tools.#{provider}.description")
      end

      def self.parameters
        {
          q: { type: "string", description: I18n.t("search.tools.params.q") },
          since_days: { type: "integer", minimum: 1, maximum: Connectors::Services::LookBack::MAX_SINCE_DAYS,
                        description: I18n.t("search.tools.params.since_days") },
          pages: { type: "integer", minimum: 1, maximum: Connectors::Services::PageLimit.max_pages,
                   description: I18n.t("search.tools.params.pages") },
          cursor: { type: "string", description: I18n.t("search.tools.params.cursor") }
        }
      end

      def self.call(**)
        new(**).call
      end

      def initialize(company:, user:, q: nil, since_days: nil, pages: nil, cursor: nil, **options)
        @company = company
        @user = user
        @q = q.to_s.strip
        @since_days = since_days.presence&.to_i
        @pages = pages.presence&.to_i
        @cursor = cursor.presence
        @options = options
      end

      def call
        raise Search::PageLimitExceeded.new(pages, max: max_pages) if pages && pages > max_pages
        raise Search::NotConnected, provider if account.nil?

        result = query(account)
        Result.new(
          provider: provider, items: matching(result.items), next_cursor: result.next_cursor,
          truncated: result.next_cursor.present?, since: result.since
        )
      end

      private

      attr_reader :company, :user, :q, :since_days, :pages, :cursor, :options

      def provider
        self.class.provider
      end

      def account
        @account ||= ConnectorAccount.for_company(company).for_provider(provider).connected.where(user_id: user.id).first
      end

      def query(_account)
        raise NotImplementedError
      end

      def query_params
        { since_days: since_days, pages: pages, cursor: cursor }.compact
      end

      def max_pages
        Connectors::Services::PageLimit.max_pages
      end

      def matching(items)
        return items if q.blank?

        needle = q.downcase
        items.select { |item| item[:title].to_s.downcase.include?(needle) }
      end
    end
  end
end
