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

    it 'says which model reviewed, so a reader can tell the tier' do
      expect(renderer.to_md).to include('_Reviewed with gpt-4o_')
    end
  end

  context 'when a Claude Code run produced the findings' do
    let(:report) do
      Thingie::Report.new(
        target: Thingie::ReviewTarget.new(
          platform: 'local', repo_url: nil, pr_number: nil, commit_sha: nil,
          branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false
        ),
        model: 'claude-sonnet-5-5',
        issues: [],
        number_of_processed_files: 2,
        details: { 'source' => 'claude_code', 'skill' => '/code-review', 'turns' => 17, 'cost_usd' => 0.42,
                   'notes' => "## Summary\nThe N+1 was confirmed against the loader." }
      )
    end

    it 'names the skill and model in the summary line' do
      expect(renderer.to_md).to include('_Reviewed with Claude Code `/code-review` (claude-sonnet-5-5)_')
    end

    it 'collapses the run details and reviewer notes under the summary', :aggregate_failures do
      output = renderer.to_md
      expect(output).to include('<details><summary>Review details</summary>')
      expect(output).to include('- **turns:** 17', '- **cost_usd:** 0.42')
      expect(output).to include("**Reviewer notes**\n\n## Summary\nThe N+1 was confirmed")
      expect(output).not_to include('- **notes:**')
    end
  end
end
