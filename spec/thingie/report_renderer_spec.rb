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

  context 'with a commit and a list of reviewed files' do
    let(:report) do
      Thingie::Report.new(
        target: Thingie::ReviewTarget.new(
          platform: 'github', repo_url: nil, pr_number: 1, commit_sha: 'abc1234def',
          branch: nil, base_ref: 'c3d89f54ef47b0392c53f6e44bb50610a03785a9', head_ref: 'HEAD', merge_base: false
        ),
        model: 'gpt-4o',
        issues: [],
        processed_files: %w[app.rb lib/foo.rb]
      )
    end

    it 'names the commit out of sight, lists the files and records the run', :aggregate_failures do
      output = renderer.to_md
      expect(output).to include('<!-- thingie-reviewed abc1234 -->')
      expect(output).not_to include('Review of')
      expect(output).to include('Files reviewed (2)', '- `app.rb`', '- `lib/foo.rb`')
      expect(output).to include('Thingie details', "Thingie version: #{Thingie::VERSION}",
                                'Review model: gpt-4o', 'Base: `c3d89f5`', 'UTC')
      expect(output).not_to include('c3d89f54ef47')
    end
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

    it 'says no changes are recommended in Markdown output, leaving the file list to say how many were reviewed',
       :aggregate_failures do
      expect(renderer.to_md).to include('**✅ No changes recommended**')
      expect(renderer.to_md).not_to include('across')
    end
  end

  context 'with a finding that carries evidence' do
    let(:report) do
      raw = Thingie::RawIssue.new(title: 'Guard skipped', severity: 2, confidence: 1, details: 'd',
                                  evidence: 'award.rb:31 skips the check',
                                  affected_lines: [Thingie::AffectedRange.new(start_line: 3, end_line: 3)])
      Thingie::Report.new(
        target: Thingie::ReviewTarget.new(platform: 'local', repo_url: nil, pr_number: nil, commit_sha: nil,
                                          branch: nil, base_ref: 'main', head_ref: 'HEAD', merge_base: false),
        model: 'm',
        issues: [Thingie::Issue.new(id: 1, file: 'app.rb', raw_issue: raw, affected_lines: raw.affected_lines)]
      )
    end

    it 'shows the evidence under the finding' do
      expect(renderer.to_md)
        .to include("<details><summary>Evidence</summary>\n\naward.rb:31 skips the check\n\n</details>")
    end
  end
end
