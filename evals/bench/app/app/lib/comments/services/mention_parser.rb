module Comments
  module Services
    class MentionParser
      HANDLE = /(?<![\w.])@([a-z0-9][a-z0-9._-]{1,38})/i

      def self.call(company:, body:)
        new(company: company, body: body).call
      end

      def initialize(company:, body:)
        @company = company
        @body = body.to_s
      end

      def call
        handles = body.scan(HANDLE).flatten.map(&:downcase).uniq
        return [] if handles.empty?

        company.users.select { |user| handles.include?(handle_for(user)) }.map(&:id)
      end

      private

      attr_reader :company, :body

      def handle_for(user)
        user.email.split("@").first.downcase
      end
    end
  end
end
