# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::GitHub::Escalator do # rubocop:disable RSpec/SpecFilePathFormat
  let(:client) { instance_double(Octokit::Client, add_labels_to_an_issue: nil, remove_label: nil) }
  let(:rules) do
    [{ 'threshold' => 0.5, 'label' => 'risk: needs review' }, { 'threshold' => 0.8, 'label' => 'risk: high' }]
  end

  before { allow(Octokit::Client).to receive(:new).and_return(client) }

  def escalator(rules: self.rules)
    described_class.new(token: 't', owner: 'o', repo: 'r', pr_number: 7, rules: Thingie::EscalationRules.new(rules))
  end

  it 'adds the label of every rule the score reaches, including a score equal to the threshold' do
    labels = escalator.call(0.8)

    expect(labels).to eq(['risk: needs review', 'risk: high'])
    expect(client).to have_received(:add_labels_to_an_issue).with('o/r', 7, ['risk: needs review', 'risk: high'])
  end

  it 'adds only the lower rule when the score stops short of the higher threshold' do
    expect(escalator.call(0.6)).to eq(['risk: needs review'])
  end

  it 'does not call GitHub when no rule matches' do
    expect(escalator.call(0.49)).to be_empty
    expect(client).not_to have_received(:add_labels_to_an_issue)
  end

  it 'removes the labels of rules the score no longer reaches' do
    escalator.call(0.6)

    expect(client).to have_received(:remove_label).with('o/r', 7, 'risk: high')
    expect(client).not_to have_received(:remove_label).with('o/r', 7, 'risk: needs review')
  end

  it 'removes every managed label when no rule matches' do
    escalator.call(0.1)

    expect(client).to have_received(:remove_label).twice
  end

  it 'ignores a label that is already off the PR' do
    allow(client).to receive(:remove_label).and_raise(Octokit::NotFound)

    expect(escalator.call(0.1)).to be_empty
  end

  it 'keeps a label shared by a matched rule' do
    shared = [{ 'threshold' => 0.2, 'label' => 'risk' }, { 'threshold' => 0.9, 'label' => 'risk' }]
    escalator(rules: shared).call(0.3)

    expect(client).not_to have_received(:remove_label)
  end
end
