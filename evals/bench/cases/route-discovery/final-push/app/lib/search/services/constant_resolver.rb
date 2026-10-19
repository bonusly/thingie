module Search
  module Services
    class ConstantResolver
      IMPORT = /^import\s*\{(?<names>[^}]*)\}\s*from\s*"(?<spec>[^"]+)"/
      REFERENCE = /\A(?<namespace>[A-Z][A-Z0-9_]*)\.(?<key>[A-Z][A-Z0-9_]*)\z/
      EXTENSIONS = %w[.ts .tsx].freeze

      def initialize(source:, router_path:, tsconfig_path:)
        @source = source
        @router_path = router_path.to_s
        @tsconfig_path = tsconfig_path.to_s
      end

      def call(reference)
        match = REFERENCE.match(reference.strip)
        raise Search::UnresolvedConstant, reference unless match

        value = constant_value(module_path(match[:namespace], reference), match[:namespace], match[:key])
        value || raise(Search::UnresolvedConstant, reference)
      end

      private

      attr_reader :source, :router_path, :tsconfig_path

      def module_path(namespace, reference)
        import = source.to_enum(:scan, IMPORT).map { Regexp.last_match }.find do |candidate|
          candidate[:names].split(",").map(&:strip).include?(namespace)
        end
        raise Search::UnresolvedConstant, reference unless import

        resolve(import[:spec]) || raise(Search::UnresolvedConstant, reference)
      end

      def resolve(spec)
        if spec.start_with?(".")
          base = File.expand_path(spec, File.dirname(router_path))
          EXTENSIONS.map { |ext| "#{base}#{ext}" }.find { |candidate| File.exist?(candidate) }
        else
          target = aliases[spec]&.first
          target && File.expand_path(target, File.dirname(tsconfig_path))
        end
      end

      def aliases
        JSON.parse(File.read(tsconfig_path)).dig("compilerOptions", "paths") || {}
      rescue Errno::ENOENT
        {}
      end

      def constant_value(path, namespace, key)
        block = File.read(path)[/export const #{namespace}\s*=\s*\{(.*?)\}/m, 1]
        block && block[/\b#{key}:\s*"([^"]*)"/, 1]
      end
    end
  end
end
