module Connectors
  module Services
    class PageLimit
      MAX_PAGES = 5

      def self.max_pages
        Rails.application.config.x.connectors.max_pages_per_call || MAX_PAGES
      end

      def self.call(max: max_pages, &)
        new(max: max).call(&)
      end

      def initialize(max:)
        @max = [max.to_i, 1].max
      end

      def call
        pages = 0
        while pages < max
          pages += 1
          break unless yield(pages)
        end
        pages
      end

      private

      attr_reader :max
    end
  end
end
