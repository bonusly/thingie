# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

module Thingie
  # Metadata about the code under review.
  ReviewTarget = Data.define(
    :platform,
    :repo_url,
    :pr_number,
    :commit_sha,
    :branch,
    :base_ref,
    :head_ref,
    :merge_base
  ) do
    # Whether the review target is a GitHub PR.
    #
    # @return [Boolean] whether the review target is a GitHub PR
    def github?
      platform == 'github'
    end

    # Whether the review target is a local working copy.
    #
    # @return [Boolean] whether the review target is a local working copy
    def local?
      platform == 'local'
    end
  end

  # A code range that an issue refers to, optionally with a proposed fix.
  AffectedRange = Struct.new(:start_line, :end_line, :proposal, :affected_code, keyword_init: true)

  # Raw issue returned by the LLM before enrichment.
  RawIssue = Data.define(
    :title,
    :details,
    :severity,
    :confidence,
    :tags,
    :affected_lines
  ) do
    # Builds a raw issue, defaulting optional fields absent from the LLM's JSON.
    #
    # @param title [String] short summary of the issue
    # @param severity [Integer] severity 1 (critical) through 4 (low)
    # @param confidence [Integer] confidence 1 (highest) through 4 (lowest)
    # @param details [String, nil] extended explanation of the issue
    # @param tags [Array<String>] issue tags (e.g. `bug`, `security`)
    # @param affected_lines [Array<Thingie::AffectedRange>] code ranges the issue refers to
    def initialize(title:, severity:, confidence:, details: nil, tags: [], affected_lines: [])
      super
    end
  end

  # Normalized issue enriched with file context and an assigned ID.
  class Issue
    attr_accessor :id
    attr_reader :file, :title, :details, :severity, :confidence, :tags, :affected_lines

    # Builds an `Issue` from a raw hash (e.g. parsed from LLM JSON output).
    #
    # @param hash [Hash] issue attributes, keyed by string or symbol
    # @return [Thingie::Issue] the normalized issue
    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_s)
      ranges = parse_affected_lines(hash['affected_lines'])
      build_from_hash(hash, ranges)
    end

    # Normalizes the `affected_lines` value from a raw hash into `AffectedRange`s.
    #
    # @param lines [Array<Hash>, Hash, nil] one or more affected-line hashes
    # @return [Array<Thingie::AffectedRange>] the parsed affected ranges
    def self.parse_affected_lines(lines)
      lines = [lines] if lines.is_a?(Hash) # a lone Hash is one range, not pairs
      Array(lines).map do |line|
        line = line.transform_keys(&:to_s) if line.respond_to?(:transform_keys)
        AffectedRange.new(
          start_line: line['start_line'],
          end_line: line['end_line'] || line['start_line'],
          proposal: line['proposal'],
          affected_code: line['affected_code']
        )
      end
    end

    # Builds an `Issue` from an already-normalized hash and affected ranges.
    #
    # @param hash [Hash] issue attributes, keyed by string
    # @param affected_lines [Array<Thingie::AffectedRange>] the parsed affected ranges
    # @return [Thingie::Issue] the built issue
    def self.build_from_hash(hash, affected_lines)
      raw = RawIssue.new(
        title: hash.fetch('title'),
        severity: hash.fetch('severity'),
        confidence: hash.fetch('confidence'),
        details: hash['details'],
        tags: hash['tags'] || [],
        affected_lines: affected_lines
      )
      new(id: hash['id'], file: hash['file'], raw_issue: raw, affected_lines: affected_lines)
    end

    # Builds a normalized issue from a raw LLM finding.
    #
    # @param id [String, Integer, nil] assigned issue identifier
    # @param file [String] path of the file the issue was found in
    # @param raw_issue [Thingie::RawIssue] the raw issue data from the LLM
    # @param affected_lines [Array<Thingie::AffectedRange>] code ranges the issue refers to
    def initialize(id:, file:, raw_issue:, affected_lines:)
      @id = id
      @file = file
      @title = raw_issue.title
      @details = raw_issue.details
      @severity = raw_issue.severity
      @confidence = raw_issue.confidence
      @tags = raw_issue.tags || []
      @affected_lines = affected_lines
    end

    # Applies a critic-supplied correction to severity and/or confidence,
    # leaving either unchanged when its argument is nil. This is the only
    # sanctioned way to mutate a built issue's grade (mirrors `id=`).
    #
    # @param severity [Integer, nil] corrected severity, or nil to leave unchanged
    # @param confidence [Integer, nil] corrected confidence, or nil to leave unchanged
    # @return [void]
    def apply_override(severity: nil, confidence: nil)
      @severity = severity unless severity.nil?
      @confidence = confidence unless confidence.nil?
    end

    # Converts the issue to a plain hash for JSON serialization.
    #
    # @return [Hash] a plain-hash representation suitable for JSON serialization
    def to_h
      {
        'id' => @id,
        'file' => @file,
        'title' => @title,
        'details' => @details,
        'severity' => @severity,
        'confidence' => @confidence,
        'tags' => @tags,
        'affected_lines' => @affected_lines.map { |range| range.to_h.transform_keys(&:to_s) }
      }
    end
  end

  # Collection of issues and metadata produced by a review run.
  class Report
    attr_reader :target, :issues, :processing_warnings, :created_at, :model,
                :number_of_processed_files, :unreviewed_files

    # Loads a `Report` from a saved JSON file.
    #
    # @param path [String] path to the JSON report file
    # @return [Thingie::Report] the loaded report
    def self.from_file(path)
      data = JSON.parse(File.read(path))
      from_hash(data)
    end

    # Parses the `"target"` hash out of raw report data.
    #
    # @param data [Hash] report data containing a `"target"` hash
    # @return [Thingie::ReviewTarget] the parsed review target
    def self.target_from_hash(data)
      target_data = (data['target'] || {}).transform_keys(&:to_s)
      ReviewTarget.new(**ReviewTarget.members.to_h { |m| [m, target_data[m.to_s]] })
    end

    # Builds a `Report` from a raw hash (e.g. parsed from JSON).
    #
    # @param data [Hash] report attributes, keyed by string
    # @return [Thingie::Report] the built report
    def self.from_hash(data)
      target = target_from_hash(data)
      issues = Array(data['issues']).map { |issue| Issue.from_hash(issue) }
      new(
        target: target,
        model: data['model'],
        issues: issues,
        processing_warnings: data['processing_warnings'] || [],
        number_of_processed_files: data['number_of_processed_files'],
        unreviewed_files: data['unreviewed_files'] || []
      )
    end

    # Builds a report from already-resolved values (see {.from_hash}/{.from_file} to parse one).
    #
    # @param target [Thingie::ReviewTarget] metadata about the code under review
    # @param model [String] the LLM model used for the review
    # @param issues [Array<Thingie::Issue>] issues found during the review
    # @param processing_warnings [Array<String>] non-fatal warnings from the review pipeline
    # @param number_of_processed_files [Integer, nil] files processed; defaults to the
    #   unique file count across `issues`
    # @param unreviewed_files [Array<String>] files the review could not read a verdict
    #   for. A report listing any of these covers less than the changeset, so the
    #   absence of findings in them means nothing.
    def initialize(target:, model:, issues: [], processing_warnings: [],
                   number_of_processed_files: nil, unreviewed_files: [])
      @target = target
      @model = model
      @issues = Array(issues)
      @processing_warnings = Array(processing_warnings)
      @unreviewed_files = Array(unreviewed_files).uniq
      @number_of_processed_files = number_of_processed_files || @issues.map(&:file).compact.uniq.size
      @created_at = Time.now.iso8601
    end

    # The total number of issues in the report.
    #
    # @return [Integer] the total number of issues in the report
    def total_issues
      @issues.size
    end

    # Converts the report to a plain hash for JSON serialization.
    #
    # @return [Hash] a plain-hash representation suitable for JSON serialization
    def to_h
      {
        'target' => @target.to_h.transform_keys(&:to_s),
        'model' => @model,
        'issues' => @issues.map(&:to_h),
        'number_of_processed_files' => number_of_processed_files,
        'total_issues' => total_issues,
        'processing_warnings' => @processing_warnings,
        'unreviewed_files' => @unreviewed_files,
        'created_at' => @created_at
      }
    end

    # Writes the report as `code-review-report.json` inside `output_dir`.
    #
    # @param output_dir [String] directory to write the report into (created if missing)
    # @return [void]
    def save(output_dir)
      FileUtils.mkdir_p(output_dir)
      File.write(File.join(output_dir, 'code-review-report.json'), JSON.pretty_generate(to_h))
    end
  end
end
