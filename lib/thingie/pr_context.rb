# frozen_string_literal: true

module Thingie
  # The PR as a whole, for prompts that each see a single file: every touched
  # path and the names the PR defines on added lines. Without it a file using
  # `GranolaGated` cannot know the same PR adds it in another file, and the
  # model reports it as undefined.
  class PrContext
    # Lines on the added side of a diff that define a name, by file extension.
    DEFINITION_PATTERNS = {
      %w[.rb .rake] => [
        /\A\s*(?:class|module)\s+([A-Z][\w:]*)/,
        /\A\s*def\s+(?:self\.)?([a-z_]\w*[?!=]?)/,
        /\A\s*([A-Z][A-Z0-9_]*)\s*=(?![=~])/,
        /\A\s*(?:factory|trait|scope)\s+:(\w+)/
      ],
      %w[.yml .yaml] => [/\A\s*["']?([\w-]+)["']?:/]
    }.freeze

    # Caps keep a sweeping PR (a rename across hundreds of files) from
    # crowding the diff out of the prompt.
    MAX_FILES = 200
    MAX_DEFINITIONS = 300

    # Builds the context for one changeset.
    #
    # @param changeset [Thingie::Changeset] the diff under review
    def initialize(changeset)
      @changeset = changeset
    end

    # Every path the PR touches, including files excluded from review. Empty
    # in `all` mode, where there is no diff.
    #
    # @return [Array<Hash>] `{ path:, status: }`, where status is a Rugged delta
    #   status such as `:added`, `:modified`, `:deleted`, or `:renamed`
    def files
      @files ||= patches.map do |patch|
        delta = patch.delta
        { path: delta.new_file[:path] || delta.old_file[:path], status: delta.status }
      end
    end

    # Ruby classes, modules, methods, constants, and FactoryBot factories,
    # traits, and scopes, plus YAML keys, defined on the PR's added lines.
    #
    # @return [Array<Hash>] `{ name:, path:, line: }`
    def definitions
      @definitions ||= patches.reject { |patch| patch.delta.binary }.flat_map do |patch|
        path = patch.delta.new_file[:path]
        patterns = DEFINITION_PATTERNS.select { |extensions, _| extensions.include?(File.extname(path)) }
                                      .values.flatten
        added_lines(patch).filter_map do |line|
          name = patterns.lazy.filter_map { |pattern| line.content[pattern, 1] }.first
          { name: name, path: path, line: line.new_lineno } if name
        end
      end
    end

    # The section text, rendered once and shared by every prompt in the run.
    #
    # @return [String] the rendered section, or '' when there is no diff (`all` mode)
    def to_s
      @to_s ||= files.empty? ? '' : [files_section, definitions_section].compact.join("\n\n")
    end

    private

    def patches
      @changeset.all? ? [] : @changeset.patches
    end

    def added_lines(patch)
      patch.each_hunk.flat_map { |hunk| hunk.each_line.select(&:addition?) }
    end

    def files_section
      lines = files.first(MAX_FILES).map { |file| "- #{file[:status]} #{file[:path]}" }
      lines << "- ...and #{files.size - MAX_FILES} more" if files.size > MAX_FILES
      "Files this PR touches:\n#{lines.join("\n")}"
    end

    def definitions_section
      return nil if definitions.empty?

      lines = definitions.first(MAX_DEFINITIONS).map { |d| "- #{d[:name]} (#{d[:path]}:#{d[:line]})" }
      lines << "- ...and #{definitions.size - MAX_DEFINITIONS} more" if definitions.size > MAX_DEFINITIONS
      "Names this PR defines on added lines:\n#{lines.join("\n")}"
    end
  end
end
