# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::ReportRenderer do
  subject(:renderer) { described_class.new(report) }

  let(:report) do
    Thingie::Report.new(
      target: Thingie::ReviewTarget.new(
        platform: 'local', repo_url: nil, pr_number: nil, commit_sha: nil,
        branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false
      ),
      model: 'gpt-4o',
      issues: [
        Thingie::Issue.new(
          id: 1,
          file: 'app.rb',
          raw_issue: Thingie::RawIssue.new(
            title: 'Unused variable',
            severity: 2,
            confidence: 1,
            details: 'x is assigned but never used',
            tags: ['maintainability'],
            affected_lines: [Thingie::AffectedRange.new(start_line: 3, end_line: 3)]
          ),
          affected_lines: [Thingie::AffectedRange.new(start_line: 3, end_line: 3)]
        )
      ]
    )
  end

  it 'renders CLI output', :aggregate_failures do
    output = renderer.to_cli
    expect(output).to include('1 issue(s) found')
    expect(output).to include('Unused variable')
    expect(output).to include('app.rb')
    expect(output).to include('[High]')
  end

  it 'renders Markdown output', :aggregate_failures do
    output = renderer.to_md
    expect(output).not_to include('Thingie Code Review')
    expect(output).to include('Unused variable')
    expect(output).to include('app.rb')
    expect(output).to include('[High]')
  end

  context 'with no issues but processed files' do
    let(:report) do
      Thingie::Report.new(
        target: Thingie::ReviewTarget.new(
          platform: 'local', repo_url: nil, pr_number: nil, commit_sha: nil,
          branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false
        ),
        model: 'gpt-4o',
        issues: [],
        number_of_processed_files: 5
      )
    end

    it 'reports the number of processed files in CLI output' do
      expect(renderer.to_cli).to include('No issues found across 5 file(s)')
    end

    it 'reports the number of processed files in Markdown output' do
      expect(renderer.to_md).to include('**✅ No issues found** across 5 file(s)')
    end
  end

  # A file with no findings and a file for which no verdict was ever produced
  # look identical via total_issues alone, so a run with unreviewed files must
  # not render as a plain clean pass in either human-facing surface.
  context 'with unreviewed files' do
    let(:report) do
      Thingie::Report.new(
        target: Thingie::ReviewTarget.new(
          platform: 'local', repo_url: nil, pr_number: nil, commit_sha: nil,
          branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false
        ),
        model: 'gpt-4o',
        issues: [],
        number_of_processed_files: 5,
        unreviewed_files: ['broken.rb', 'blank.rb']
      )
    end

    it 'discloses the unreviewed files in CLI output rather than reading as a clean pass', :aggregate_failures do
      output = renderer.to_cli
      expect(output).to include('No issues found across 3 of 5 file(s)')
      expect(output).to include('2 file(s) could not be reviewed: broken.rb, blank.rb')
    end

    it 'discloses the unreviewed files in Markdown output rather than reading as a clean pass', :aggregate_failures do
      output = renderer.to_md
      expect(output).to include('**✅ No issues found** across 3 of 5 file(s)')
      expect(output).to include('**⚠️ 2 file(s) could not be reviewed:** broken.rb, blank.rb')
    end
  end

  # The issues-found headline must apply the same reviewed-of-total coverage
  # count as the clean-pass headline — otherwise a run with both findings and
  # unreviewed files claims full coverage in one branch and not the other.
  context 'with issues found and unreviewed files' do
    let(:report) do
      Thingie::Report.new(
        target: Thingie::ReviewTarget.new(
          platform: 'local', repo_url: nil, pr_number: nil, commit_sha: nil,
          branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false
        ),
        model: 'gpt-4o',
        issues: [
          Thingie::Issue.new(
            id: 1, file: 'app.rb',
            raw_issue: Thingie::RawIssue.new(
              title: 'Unused variable', severity: 2, confidence: 1, details: 'x is unused',
              tags: ['maintainability'], affected_lines: [Thingie::AffectedRange.new(start_line: 3, end_line: 3)]
            ),
            affected_lines: [Thingie::AffectedRange.new(start_line: 3, end_line: 3)]
          )
        ],
        number_of_processed_files: 5,
        unreviewed_files: ['broken.rb', 'blank.rb']
      )
    end

    it 'reports reviewed-of-total coverage in the CLI headline, not the full file count' do
      expect(renderer.to_cli).to include('1 issue(s) found across 3 of 5 file(s)')
    end

    it 'reports reviewed-of-total coverage in the Markdown headline, not the full file count' do
      expect(renderer.to_md).to include('**⚠️ 1 issue(s) found** across 3 of 5 file(s)')
    end
  end
end
