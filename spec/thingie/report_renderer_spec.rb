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

  context 'with a change risk' do
    let(:change_risk) do
      { 'model' => 'jev-latest', 'max' => { 'user_impact' => 0.9, 'overall' => 0.52 }, 'rating' => 'risky',
        'files' => { 'spec/a_spec.rb' => { 'scores' => { 'user_impact' => 0.0, 'overall' => 0.05 },
                                           'rating' => 'trivial' },
                     'lib/a.rb' => { 'scores' => { 'user_impact' => 0.9, 'overall' => 0.52 }, 'rating' => 'risky' } },
        'escalations' => [{ 'label' => 'risk: needs review' }] }
    end

    before { report.change_risk = change_risk }

    it "shows the rating, each file's scores and the escalations in Markdown", :aggregate_failures do
      output = renderer.to_md
      expect(output).to include('Change risk: risky (review need 0.52), escalated: `risk: needs review`')
      expect(output).to include("| File | Rating | Review need | User impact |\n| --- | --- | --- | --- |\n" \
                                "| `lib/a.rb` | risky | 0.52 | 0.90 |\n| `spec/a_spec.rb` | trivial | 0.05 | 0.00 |")
      expect(output).to include("Escalations:\n\n- `risk: needs review`")
    end

    it 'lists files riskiest first with their scores and the escalations in CLI output', :aggregate_failures do
      output = renderer.to_cli
      expect(output).to include("Change risk: risky (review need 0.52), escalated: `risk: needs review`\n  " \
                                "- lib/a.rb: risky (review need 0.52; user impact 0.90)\n  " \
                                "- spec/a_spec.rb: trivial (review need 0.05; user impact 0.00)\n")
      expect(output).to include("Escalations:\n  - risk: needs review")
    end

    it 'names the decision model beside the review model' do
      expect(renderer.to_md).to include("- Review model: gpt-4o\n- Decision model: jev-latest\n")
    end

    context 'when the escalation has a title and description' do
      let(:change_risk) do
        { 'max' => { 'overall' => 0.9 }, 'files' => {},
          'escalations' => [{ 'label' => 'risk: high', 'title' => 'High risk',
                              'description' => 'Ask a second reviewer.' }] }
      end

      it 'puts them in the Markdown summary, with the label alongside', :aggregate_failures do
        output = renderer.to_md
        expect(output).to include('Change risk: review need 0.90, escalated: High risk')
        expect(output).to include('- **High risk** (`risk: high`): Ask a second reviewer.')
      end

      it 'puts them in the CLI output, with the label alongside' do
        expect(renderer.to_cli).to include('  - High risk (risk: high): Ask a second reviewer.')
      end
    end

    it 'says no escalation was taken when none applied', :aggregate_failures do
      change_risk['escalations'] = []
      expect(renderer.to_md).to include('Change risk: risky (review need 0.52)</summary>', 'Escalations: none')
      expect(renderer.to_cli).to include('Escalations: none')
    end

    it 'says no files were scored when there are no scores', :aggregate_failures do
      change_risk.merge!('max' => {}, 'rating' => nil, 'files' => {}, 'escalations' => [])
      expect(renderer.to_md).to include('Change risk: no files scored', 'No files were scored.')
      expect(renderer.to_cli).to include('Change risk: no files scored')
    end

    it 'survives a round trip through the saved report' do
      restored = Thingie::Report.from_hash(JSON.parse(JSON.generate(report.to_h)))

      expect(restored.change_risk).to eq(change_risk)
    end
  end

  it 'omits the change risk section when System One did not score the change', :aggregate_failures do
    expect(renderer.to_md).not_to include('Change risk')
    expect(renderer.to_cli).not_to include('Change risk')
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
