# frozen_string_literal: true

module Thingie
  # The files a PR touches, for prompts that each see a single file. Without
  # it a file using `GranolaGated` cannot know the same PR adds
  # `granola_gated.rb`, and the model reports the constant as undefined. Paths
  # only, not contents or definitions, so the model can look a file up when
  # it needs to without the prompt growing with the PR.
  class PrContext
    # Cap keeps a sweeping PR (a rename across hundreds of files) from
    # crowding the diff out of the prompt.
    MAX_FILES = 200

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

    # The prompt section listing the touched files (up to MAX_FILES), rendered
    # once and shared by every prompt in the run.
    #
    # @return [String] the rendered section, or '' when there is no diff (`all` mode)
    def to_s
      @to_s ||= files.empty? ? '' : files_section
    end

    private

    def patches
      @changeset.all? ? [] : @changeset.patches
    end

    def files_section
      lines = files.first(MAX_FILES).map { |file| "- #{file[:status]} #{file[:path]}" }
      lines << "- ...and #{files.size - MAX_FILES} more" if files.size > MAX_FILES
      "Files this PR touches:\n#{lines.join("\n")}"
    end
  end
end
