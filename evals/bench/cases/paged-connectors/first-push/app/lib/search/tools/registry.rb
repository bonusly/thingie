module Search
  module Tools
    class Registry
      TOOLS = [Search::Tools::GithubSearch, Search::Tools::SlackSearch, Search::Tools::LinearSearch].freeze

      def self.all
        TOOLS
      end

      def self.for(providers)
        wanted = Array(providers).map(&:to_s).reject(&:blank?)
        return all if wanted.empty?

        wanted.map { |provider| find(provider) }
      end

      def self.find(provider)
        all.find { |tool| tool.provider == provider.to_s } || raise(Connectors::UnknownProvider, provider)
      end

      def self.definitions
        all.map { |tool| { name: "#{tool.provider}_search", description: tool.description, parameters: tool.parameters } }
      end
    end
  end
end
