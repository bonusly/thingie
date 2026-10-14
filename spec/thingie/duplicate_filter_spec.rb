# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::DuplicateFilter do
  subject(:filter) { described_class.new(llm_client: llm_client, prompt_builder: prompt_builder) }

  let(:prompt_builder) { Thingie::PromptBuilder.new(Thingie::Configuration.new(root: Dir.mktmpdir)) }

  let(:llm_client) { instance_double(Thingie::LlmClient) }
  let(:open_comments) { [{ file: 'a.rb', line: 3, text: 'Query never returns users' }] }

  # Findings are labelled N1.. in severity order (most severe first), so the
  # severities below make the labels match the issue names.
  let(:critical) { issue('critical', severity: 1) }
  let(:high) { issue('high', severity: 2) }
  let(:medium) { issue('medium', severity: 3) }

  def issue(title, severity:)
    Thingie::Issue.from_hash('title' => title, 'details' => "#{title} details", 'severity' => severity,
                             'confidence' => 3, 'tags' => [], 'file' => 'a.rb',
                             'affected_lines' => [{ 'start_line' => 3 }])
  end

  def reply(pairs)
    findings = pairs.map { |id, duplicate_of| { 'id' => id, 'duplicate_of' => duplicate_of } }
    instance_double(RubyLLM::Message, content: { 'findings' => findings }.to_json)
  end

  def answer_with(pairs)
    allow(llm_client).to receive(:complete_with_schema).and_return(reply(pairs))
  end

  it 'makes no model call for a single finding with nothing open' do
    allow(llm_client).to receive(:complete_with_schema)

    expect(filter.call([critical], [])).to eq([critical])
    expect(llm_client).not_to have_received(:complete_with_schema)
  end

  it 'drops a finding that repeats an open comment' do
    answer_with([%w[N1 E1]])

    expect(filter.call([critical], open_comments)).to eq([])
  end

  it 'keeps the most severe of several repeats and the original order of the rest', :aggregate_failures do
    answer_with([['N1', nil], %w[N2 N1], ['N3', nil]])

    expect(filter.call([medium, high, critical], [])).to eq([medium, critical])
  end

  it 'drops a finding whose pointer chain leads back to a repeat' do
    answer_with([['N1', nil], %w[N2 N1], %w[N3 N2]])

    expect(filter.call([critical, high, medium], [])).to eq([critical])
  end

  it 'keeps findings the model says are new' do
    answer_with([['N1', nil], ['N2', nil]])

    expect(filter.call([critical, high], open_comments)).to eq([critical, high])
  end

  it 'ignores a pointer to itself, to a later finding or to an unknown label' do
    answer_with([%w[N1 N1], %w[N2 N3], %w[N3 X9]])

    expect(filter.call([critical, high, medium], [])).to eq([critical, high, medium])
  end

  it 'ignores a pointer to an open comment that does not exist' do
    answer_with([%w[N1 E4]])

    expect(filter.call([critical], open_comments)).to eq([critical])
  end

  it 'shows the model the open comments and the new findings', :aggregate_failures do
    allow(llm_client).to receive(:complete_with_schema).and_return(reply([['N1', nil]]))

    filter.call([critical], open_comments)

    expect(llm_client).to have_received(:complete_with_schema)
      .with(a_string_including('E1 | a.rb:3', 'Query never returns users', 'N1 | a.rb:3', 'critical details'),
            Thingie::Schemas::DUPLICATES_SCHEMA)
  end

  it 'reads a reply the client has already parsed into a hash' do
    parsed = { 'findings' => [{ 'id' => 'N1', 'duplicate_of' => 'E1' }] }
    allow(llm_client).to receive(:complete_with_schema).and_return(instance_double(RubyLLM::Message, content: parsed))

    expect(filter.call([critical], open_comments)).to eq([])
  end

  it 'raises when the reply has no findings list, so the caller can fall back' do
    allow(llm_client).to receive(:complete_with_schema).and_return(instance_double(RubyLLM::Message, content: '{}'))

    expect { filter.call([critical], open_comments) }.to raise_error(ArgumentError, /no findings list/)
  end
end
