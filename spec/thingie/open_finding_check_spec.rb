# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::OpenFindingCheck do
  subject(:check) { described_class.new(llm_client: llm_client, prompt_builder: prompt_builder) }

  let(:prompt_builder) { Thingie::PromptBuilder.new(Thingie::Configuration.new(root: Dir.mktmpdir)) }
  let(:llm_client) { instance_double(Thingie::LlmClient) }
  let(:findings) do
    [{ id: 'T1', file: 'a.rb', line: 3, text: 'Query never returns users' },
     { id: 'T2', file: 'a.rb', line: 9, text: 'Crash on nil' }]
  end

  def reply(pairs)
    entries = pairs.map { |id, status| { 'id' => id, 'status' => status } }
    instance_double(RubyLLM::Message, content: { 'findings' => entries }.to_json)
  end

  def answer_with(pairs)
    allow(llm_client).to receive(:complete_with_schema).and_return(reply(pairs))
  end

  it 'maps each finding to what the model said about it' do
    answer_with('F1' => 'fixed', 'F2' => 'still_present')

    expect(check.call(findings) { "x = 1\n" }).to eq('T1' => :fixed, 'T2' => :open)
  end

  it 'treats a finding the model skipped or answered oddly as unsure' do
    answer_with('F1' => 'resolved')

    expect(check.call(findings) { "x = 1\n" }).to eq('T1' => :unsure, 'T2' => :unsure)
  end

  it 'makes one call per file and shows the file with line numbers', :aggregate_failures do
    prompts = []
    allow(llm_client).to receive(:complete_with_schema) do |prompt, _schema|
      prompts << prompt
      reply('F1' => 'fixed')
    end
    other = { id: 'T3', file: 'b.rb', line: 1, text: 'Wrong total' }

    check.call(findings.first(1) + [other]) { |path| "first #{path}\nsecond\n" }

    expect(prompts.size).to eq(2)
    expect(prompts.first).to include('1: first a.rb', '2: second', 'Query never returns users')
  end

  it 'marks every finding fixed, without a model call, when the file is gone', :aggregate_failures do
    allow(llm_client).to receive(:complete_with_schema)

    expect(check.call(findings) { nil }).to eq('T1' => :fixed, 'T2' => :fixed)
    expect(llm_client).not_to have_received(:complete_with_schema)
  end

  it 'tells the model when the file was cut off' do
    prompt = nil
    allow(llm_client).to receive(:complete_with_schema) do |text, _schema|
      prompt = text
      reply('F1' => 'unsure')
    end

    check.call(findings.first(1)) { 'x' * (described_class::CONTENT_LIMIT + 1) }

    expect(prompt).to include('cut off')
  end

  it 'lets a failed model call reach the caller, so it can fall back' do
    allow(llm_client).to receive(:complete_with_schema).and_raise(StandardError, 'boom')

    expect { check.call(findings) { "x\n" } }.to raise_error(StandardError, 'boom')
  end

  it 'raises when the reply has no findings list, so the caller can fall back' do
    allow(llm_client).to receive(:complete_with_schema).and_return(instance_double(RubyLLM::Message, content: '{}'))

    expect { check.call(findings) { "x\n" } }.to raise_error(ArgumentError, /no findings list/)
  end
end
