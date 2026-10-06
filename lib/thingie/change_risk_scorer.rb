# frozen_string_literal: true

module Thingie
  # Scores each reviewed file of a changeset with a System One model and reports the
  # riskiest file per question. Each request carries only that file's capped, comment-stripped
  # diff plus the PR's file list, not whole files, so it stays inside the model's context window.
  #
  # The scores are a one-way signal: they can raise a flag but must never lower scrutiny or
  # gate approval. The PR author controls the diff, so the model can be nudged. Obfuscation
  # findings come from the pattern-based {ObfuscationDetector}, which the model can't be argued out of.
  class ChangeRiskScorer
    # Measured against Jev's 32K-token window: the questions plus 200 paths cost about 4.8K tokens and
    # dense JSON runs about 1.7 chars per token. 24K chars stays under the limit even at 1 char per token.
    MAX_DIFF_CHARS = 24_000

    # @!attribute [r] files
    #   Path => question => score for each scored file.
    #   @return [Hash{String => Hash{Symbol => Float}}]
    # @!attribute [r] max
    #   Highest score per question across all files.
    #   @return [Hash{Symbol => Float}]
    # @!attribute [r] obfuscation
    #   Pattern-based obfuscation findings, independent of the scores.
    #   @return [Array<Thingie::Issue>]
    Result = Data.define(:files, :max, :obfuscation)

    # Build a scorer for one changeset.
    #
    # @param changeset [Thingie::Changeset] the changes to score
    # @param classifier [Thingie::SystemOneClassifier] client for the System One model
    # @param concurrency [Integer] maximum files scored at once
    def initialize(changeset:, classifier:, concurrency: 10)
      @changeset = changeset
      @classifier = classifier
      @concurrency = concurrency
      @pr_files = pr_file_list
    end

    # Score every reviewed file.
    #
    # @param questions [Hash{Symbol => Hash}] System One questions; defaults to the classifier's risk questions
    # @return [Thingie::ChangeRiskScorer::Result] per-file scores, per-question maximums, and obfuscation findings
    # @raise [Thingie::SystemOneError] if any file fails to score; a partial result could understate the risk
    def call(questions: SystemOneClassifier::RISK_QUESTIONS)
      scored = Concurrency.map(@changeset.files, @concurrency) do |file|
        state = state_for(file)
        [file, @classifier.classify(state: state, questions: questions)] if state
      end.compact.to_h

      Result.new(files: scored, max: max_per_question(scored), obfuscation: ObfuscationDetector.new(@changeset).call)
    end

    private

    def state_for(file)
      diff = @changeset.diff_text_for(file)
      return nil if diff.nil?

      diff = strip_comments(diff)
      patch = patches[file]
      added, removed = patch&.stat
      { path: file, status: patch&.delta&.status, language: File.extname(file).delete_prefix('.'),
        lines_added: added, lines_removed: removed, diff: diff[0, MAX_DIFF_CHARS],
        diff_truncated: diff.size > MAX_DIFF_CHARS, pr_files: @pr_files }
    end

    # Drops whole-line `#` and `//` comments, the easiest place for a PR author to talk the
    # model down. Block comments and trailing comments remain, so this reduces the channel
    # rather than closing it.
    def strip_comments(diff)
      diff.each_line.reject do |line|
        line.match?(/\A[+\- ]/) && line[1..].match?(ObfuscationDetector::COMMENT_LINE)
      end.join
    end

    def patches
      @patches ||= @changeset.patches.to_h { |patch| [patch.delta.new_file[:path], patch] }
    end

    def pr_file_list
      PrContext.new(@changeset).files.first(PrContext::MAX_FILES).map { |file| "#{file[:status]} #{file[:path]}" }
    end

    def max_per_question(scored)
      scored.values.flat_map(&:to_a).group_by(&:first).transform_values { |pairs| pairs.map(&:last).max }
    end
  end
end
