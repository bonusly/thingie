# frozen_string_literal: true

module Thingie
  # Scores each reviewed file of a changeset with a System One model, rates each file by its
  # `overall` score (see {RiskQuestions#rating_for}), and reports the riskiest file per
  # question. Each request carries only that file's capped, comment-stripped
  # diff plus the PR's file list, not whole files, so it stays inside the model's context window.
  #
  # The scores can raise a flag, and on a file rated trivial or routine they lower the bar on non-security
  # findings (see {PostProcessor#split_confidence}); they never gate approval. The PR author controls the
  # diff, so the model can be nudged: a Critical at confidence 1 and any `security` finding survive regardless,
  # and obfuscation findings come from the pattern-based {ObfuscationDetector}, which the model can't be
  # argued out of.
  class ChangeRiskScorer
    # Measured against Jev's 32K-token window: the questions plus 200 paths cost about 4.8K tokens and
    # dense JSON runs about 1.7 chars per token. 24K chars stays under the limit even at 1 char per token.
    MAX_DIFF_CHARS = 24_000

    # @!attribute [r] scores
    #   Question => score for the file, as returned by {SystemOneClassifier#classify}.
    #   @return [Hash{Symbol => Float}]
    # @!attribute [r] rating
    #   The file's rating, one of {RiskQuestions::LEVELS}.
    #   @return [String]
    FileRisk = Data.define(:scores, :rating)

    # @!attribute [r] files
    #   Path => scores and rating for each scored file.
    #   @return [Hash{String => FileRisk}]
    # @!attribute [r] max
    #   Highest score per question across all files.
    #   @return [Hash{Symbol => Float}]
    # @!attribute [r] rating
    #   Rating of the highest `overall` score, or nil when nothing was scored.
    #   @return [String, nil]
    # @!attribute [r] obfuscation
    #   Pattern-based obfuscation findings, independent of the scores.
    #   @return [Array<Thingie::Issue>]
    Result = Data.define(:files, :max, :rating, :obfuscation)

    # Build a scorer for one changeset.
    #
    # @param changeset [Thingie::Changeset] the changes to score
    # @param classifier [Thingie::SystemOneClassifier] client for the System One model
    # @param risk_questions [Thingie::RiskQuestions] the questions to ask and the ratings for their answers
    # @param concurrency [Integer] maximum files scored at once
    def initialize(changeset:, classifier:, risk_questions:, concurrency: 10)
      @changeset = changeset
      @classifier = classifier
      @risk_questions = risk_questions
      @concurrency = concurrency
      @pr_files = pr_file_list
    end

    # Score and rate every reviewed file.
    #
    # @return [Thingie::ChangeRiskScorer::Result] per-file scores and ratings, per-question maximums, the
    #   changeset's rating, and obfuscation findings
    # @raise [Thingie::SystemOneError] if any file fails to score; a partial result could understate the risk
    def call
      scored = Concurrency.map(@changeset.files, @concurrency) do |file|
        state = state_for(file)
        [file, file_risk(@classifier.classify(state: state, questions: @risk_questions.questions))] if state
      end.compact.to_h

      max = max_per_question(scored.transform_values(&:scores))
      rating = @risk_questions.rating_for(max[:overall]) if max[:overall]
      Result.new(files: scored, max: max, rating: rating, obfuscation: ObfuscationDetector.new(@changeset).call)
    end

    private

    def file_risk(scores)
      FileRisk.new(scores: scores, rating: @risk_questions.rating_for(scores.fetch(:overall)))
    end

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
      files = PrContext.new(@changeset).files
      list = files.first(PrContext::MAX_FILES).map { |file| "#{file[:status]} #{file[:path]}" }
      list << "...and #{files.size - PrContext::MAX_FILES} more" if files.size > PrContext::MAX_FILES
      list
    end

    def max_per_question(scored)
      scored.values.flat_map(&:to_a).group_by(&:first).transform_values { |pairs| pairs.map(&:last).max }
    end
  end
end
