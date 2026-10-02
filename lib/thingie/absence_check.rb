# frozen_string_literal: true

module Thingie
  # Drops findings that claim something is missing when the PR itself adds
  # it, e.g. "`GranolaGated` is not defined" on a PR that adds
  # `class GranolaGated`, or "partial `_tile_content` does not exist" on a PR
  # that adds `_tile_content.html.erb`. Pattern-based for the same reason as
  # ObfuscationDetector: the model was already told to look these up and
  # often didn't, so the check cannot be left to its discretion.
  #
  # A finding is dropped only when it makes an absence claim AND its subject,
  # the first name in its title (or details, if the title names nothing),
  # matches something the PR adds. So "`Gates::Farewell` is undefined; Gates
  # only defines `Greeting`" survives a PR that adds `Greeting`, and "missing
  # nil check on `user`" survives unless the PR defines `user`.
  class AbsenceCheck
    ABSENCE_CLAIM = /\b(?:undefined|not\s+defined|never\s+defined|(?:does|do)\s*n[o']t\s+exist|not\s+exist|
                       non-?existent|not\s+found|no\s+such|missing|uninitialized|(?:not\s+|un)resolvable|
                       no\s+definition)\b/xi
    BACKTICKED = /`([^`\n]+)`/
    # Names the model leaves unquoted, as in "GranolaGated constant is not
    # resolvable": multi-word CamelCase, namespaced constants, and file names.
    # Bare lowercase words are skipped; "user" in prose is too common to trust.
    BARE_NAME = %r{\b(?:[A-Z][a-z0-9]+){2,}\w*(?:::[A-Z]\w*)*|\b[A-Z]\w*(?:::[A-Z]\w*)+|[\w/]+\.(?:rb|erb|rake|ya?ml)\b}
    NAME = /#{BACKTICKED}|#{BARE_NAME}/
    MIN_NAME_LENGTH = 3

    # Builds a check against one PR.
    #
    # @param pr_context [Thingie::PrContext] supplies touched files and added definitions
    def initialize(pr_context)
      @pr_context = pr_context
    end

    # Split findings into those to keep and those the PR's own additions disprove.
    #
    # @param issues [Array<Thingie::Issue>] findings after the threshold filter
    # @return [Array(Array<Thingie::Issue>, Array<Array(Thingie::Issue, String)>)]
    #   kept issues, and dropped issues each paired with the name that disproved it
    def call(issues)
      kept = []
      dropped = []
      issues.each do |issue|
        name = disproving_name(issue)
        name ? dropped << [issue, name] : kept << issue
      end
      [kept, dropped]
    end

    private

    def disproving_name(issue)
      return nil unless "#{issue.title}\n#{issue.details}".match?(ABSENCE_CLAIM)

      subject = first_name(issue.title) || first_name(issue.details)
      subject if subject && added?(subject)
    end

    def first_name(text)
      match = text.to_s.match(NAME)
      match && (match[1] || match[0])
    end

    def added?(token)
      defined_names.intersect?(name_candidates(token)) ||
        (path_like?(token) && added_file_names.include?(file_name(token)))
    end

    # `Foo::Bar#baz` -> baz, `:checkout_visit` -> checkout_visit,
    # `.unavailable` (a relative i18n key) -> unavailable.
    def name_candidates(token)
      last = token.split(%r{::|#|\.|/}).reject(&:empty?).last.to_s.delete_prefix(':').delete_prefix('@')
      [last, token.strip].select { |name| name.length >= MIN_NAME_LENGTH }
    end

    def path_like?(token)
      token.include?('/') || token.start_with?('_') || token.match?(/\.[a-z]+\z/)
    end

    # `app/views/shared/_tile_content.html.erb` and `shared/tile_content` both -> tile_content.
    def file_name(path)
      File.basename(path).delete_prefix('_').split('.').first.to_s
    end

    def defined_names
      @defined_names ||= @pr_context.definitions.flat_map do |definition|
        [definition[:name], definition[:name].split('::').last]
      end.uniq
    end

    def added_file_names
      @added_file_names ||= @pr_context.files.reject { |file| file[:status] == :deleted }
                                       .map { |file| file_name(file[:path]) }.uniq
    end
  end
end
