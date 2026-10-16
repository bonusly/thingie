module Search
  module Queries
    class DiscoverRoutes
      Route = Struct.new(:path, :name, :component, :permission, :flag, keyword_init: true) do
        def gated?
          permission.present?
        end

        def flagged?
          flag.present?
        end

        def dynamic?
          path.to_s.include?(":")
        end

        def readable?
          path.to_s.start_with?("/") && name.present? && component.present?
        end
      end

      DEFAULT_ROUTER = "app/javascript/app-router.tsx".freeze
      DEFAULT_TSCONFIG = "tsconfig.json".freeze

      def self.call(router_path: Rails.root.join(DEFAULT_ROUTER), tsconfig_path: Rails.root.join(DEFAULT_TSCONFIG))
        new(router_path: router_path, tsconfig_path: tsconfig_path).call
      end

      def initialize(router_path:, tsconfig_path:)
        @router_path = router_path
        @tsconfig_path = tsconfig_path
      end

      def call
        source = read_source
        resolver = Search::Services::ConstantResolver.new(source: source, router_path: router_path, tsconfig_path: tsconfig_path)
        routes = Search::Services::RouteParser.new(source: source, resolver: resolver, path: router_path).call
        raise Search::RouterEmpty, router_path if routes.empty?

        routes.sort_by.with_index { |route, index| [route.dynamic? ? 1 : 0, index] }
      end

      private

      attr_reader :router_path, :tsconfig_path

      def read_source
        File.read(router_path)
      rescue Errno::ENOENT
        raise Search::RouterMissing, router_path
      rescue SystemCallError => e
        raise Search::FetchFailed.new(router_path, e)
      end
    end
  end
end
