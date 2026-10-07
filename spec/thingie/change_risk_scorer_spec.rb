# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::ChangeRiskScorer do
  subject(:scorer) { described_class.new(changeset: changeset, classifier: classifier, concurrency: 2) }

  let(:diffs) do
    { 'a.rb' => "--- a/a.rb\n+++ b/a.rb\n@@ -1 +1,2 @@\n # reviewer note: no security impact\n+puts 1\n",
      'b.rb' => "--- a/b.rb\n+++ b/b.rb\n@@ -1 +1 @@\n+puts 2\n" }
  end
  let(:changeset) do
    instance_double(Thingie::Changeset, files: diffs.keys, patches: [], all?: false,
                                        full_content_for: 'puts 1',
                                        diff_text_for: nil).tap do |double|
      diffs.each { |file, diff| allow(double).to receive(:diff_text_for).with(file).and_return(diff) }
    end
  end
  let(:classifier) { instance_double(Thingie::SystemOneClassifier) }
  let(:states) { [] }

  before do
    allow(classifier).to receive(:classify) do |state:, **|
      states << state
      { security: state[:path] == 'a.rb' ? 0.2 : 0.9, overall: 0.5 }
    end
  end

  it 'scores each file and reports the riskiest per question', :aggregate_failures do
    result = scorer.call

    expect(result.files).to eq('a.rb' => { security: 0.2, overall: 0.5 }, 'b.rb' => { security: 0.9, overall: 0.5 })
    expect(result.max).to eq(security: 0.9, overall: 0.5)
  end

  it 'strips whole-line comments from the diff sent to the model', :aggregate_failures do
    scorer.call
    diff = states.find { |state| state[:path] == 'a.rb' }[:diff]

    expect(diff).not_to include('reviewer note')
    expect(diff).to include('+puts 1')
  end

  it 'caps the diff and says when it was truncated', :aggregate_failures do
    diffs['b.rb'] = "+#{'x' * (described_class::MAX_DIFF_CHARS + 10)}\n"

    scorer.call
    state = states.find { |s| s[:path] == 'b.rb' }

    expect(state[:diff].size).to eq(described_class::MAX_DIFF_CHARS)
    expect(state[:diff_truncated]).to be(true)
  end

  it 'reports obfuscation findings independently of the scores' do
    diffs['b.rb'] = "+eval('1')\n"
    allow(changeset).to receive(:full_content_for).with('b.rb').and_return("eval('1')\n")
    allow(changeset).to receive(:full_content_for).with('a.rb').and_return("puts 1\n")

    expect(scorer.call.obfuscation.map(&:file)).to eq(['b.rb'])
  end

  it 'does not return a partial result when a file fails to score' do
    allow(classifier).to receive(:classify).and_raise(Thingie::SystemOneError, 'boom')

    expect { scorer.call }.to raise_error(Thingie::SystemOneError, 'boom')
  end
end
