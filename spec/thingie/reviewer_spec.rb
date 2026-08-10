# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::Reviewer do
  subject(:reviewer) do
    described_class.new(
      config: config,
      changeset: fake_changeset,
      prompt_builder: Thingie::PromptBuilder.new(config),
      llm_client: fake_llm_client
    )
  end

  let(:tmp_dir) { Dir.mktmpdir }
  let(:config) { Thingie::Configuration.new(root: tmp_dir) }
  let(:fake_changeset) do
    instance_double(Thingie::Changeset,
                    files: ['app.rb'],
                    diff_text_for: "+ def hello\n",
                    full_content_for: "def hello\nend\n",
                    changed_lines_for: Set.new([1]),
                    base_ref: 'main',
                    head_ref: 'HEAD',
                    head_sha: 'abc123')
  end
  let(:fake_llm_client) do
    issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
    cost_stub = instance_double(RubyLLM::Cost, total: 0.000150)
    response = instance_double(RubyLLM::Message, content: { 'issues' => issues },
                                                 input_tokens: 100, output_tokens: 50, tool_calls: {},
                                                 cache_read_tokens: nil, cache_write_tokens: nil, cost: cost_stub,
                                                 model_info: nil, thinking: nil, thinking_tokens: nil)
    instance_double(Thingie::LlmClient, complete_with_schema: response)
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  it 'returns a report with parsed issues', :aggregate_failures do
    report = reviewer.review
    expect(report).to be_a(Thingie::Report)
    expect(report.total_issues).to eq(1)
    expect(report.issues.first.title).to eq('Missing return')
    expect(report.issues.first.id).to eq(1)
    expect(report.number_of_processed_files).to eq(1)
  end

  it 'accumulates LLM usage and enriches the target with the head commit sha', :aggregate_failures do
    report = reviewer.review
    expect(reviewer.usage).to be_a(Thingie::Stats::Usage)
    # The review pass records the response once; the enabled critic pass records it again.
    expect(reviewer.usage.input_tokens).to eq(200)
    expect(reviewer.usage.output_tokens).to eq(100)
    expect(reviewer.usage.cost).to be_within(1e-9).of(0.0003)
    expect(report.target.commit_sha).to eq('abc123')
  end

  context 'when an issue falls on an unchanged line' do
    let(:fake_changeset) do
      instance_double(Thingie::Changeset,
                      files: ['app.rb'],
                      diff_text_for: "+ def hello\n",
                      full_content_for: "def hello\nend\n",
                      changed_lines_for: Set.new([5]), # issue is on line 1, not changed
                      base_ref: 'main',
                      head_ref: 'HEAD',
                      head_sha: 'abc123')
    end

    it 'drops findings outside the changed lines' do
      expect(reviewer.review.total_issues).to eq(0)
    end
  end

  context 'when the LLM client raises a connection error' do
    let(:connection_error) { Class.new(StandardError) }
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema)
          .and_raise(connection_error, 'Failed to open TCP connection')
      end
    end

    it 'propagates the error instead of silently returning no issues' do
      expect do
        reviewer.review
      end.to raise_error(RuntimeError, /Parallel review failures.*Failed to open TCP connection/m)
    end
  end

  context 'when the LLM returns malformed JSON' do
    let(:fake_llm_client) do
      response = instance_double(RubyLLM::Message, content: 'not valid json',
                                                   input_tokens: nil, output_tokens: nil, tool_calls: {},
                                                   cache_read_tokens: nil, cache_write_tokens: nil,
                                                   cost: instance_double(RubyLLM::Cost, total: nil),
                                                   thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient, complete_with_schema: response)
    end

    it 'records a warning and continues with no issues for that file', :aggregate_failures do
      report = reviewer.review
      expect(report.total_issues).to eq(0)
      expect(report.processing_warnings).to include(/Could not parse LLM response for app.rb/)
    end
  end

  context 'when the LLM returns a nil response' do
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient, complete_with_schema: nil)
    end

    it 'treats the file as having no issues' do
      expect(reviewer.review.total_issues).to eq(0)
    end
  end

  context 'when the LLM returns a response with nil content' do
    let(:fake_llm_client) do
      response = instance_double(RubyLLM::Message, content: nil,
                                                   input_tokens: nil, output_tokens: nil, tool_calls: {},
                                                   cache_read_tokens: nil, cache_write_tokens: nil,
                                                   cost: instance_double(RubyLLM::Cost, total: nil),
                                                   thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient, complete_with_schema: response)
    end

    it 'treats the file as having no issues' do
      expect(reviewer.review.total_issues).to eq(0)
    end
  end

  context 'when the LLM returns a raw JSON array string (fallback)' do
    let(:fake_llm_client) do
      json = '[{"title":"Bug","details":"desc","severity":1,"confidence":1,' \
             '"tags":[],"affected_lines":[{"start_line":1}]}]'
      cost_stub = instance_double(RubyLLM::Cost, total: nil)
      response = instance_double(RubyLLM::Message, content: json,
                                                   input_tokens: 80, output_tokens: 40, tool_calls: {},
                                                   cache_read_tokens: nil, cache_write_tokens: nil, cost: cost_stub,
                                                   thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient, complete_with_schema: response)
    end

    it 'parses the array response', :aggregate_failures do
      report = reviewer.review
      expect(report.total_issues).to eq(1)
      expect(report.issues.first.title).to eq('Bug')
    end
  end

  context 'when the LLM returns reasoning prose before the JSON payload' do
    let(:fake_llm_client) do
      prose = "I'll analyze this diff carefully.\n\n" \
              "Let me check the code for issues.\n\n" \
              '{"issues":[{"title":"Bug","details":"desc","severity":1,' \
              '"confidence":1,"tags":[],"affected_lines":[{"start_line":1}]}]}'
      cost_stub = instance_double(RubyLLM::Cost, total: nil)
      response = instance_double(RubyLLM::Message, content: prose,
                                                   input_tokens: 80, output_tokens: 40, tool_calls: {},
                                                   cache_read_tokens: nil, cache_write_tokens: nil,
                                                   cost: cost_stub,
                                                   thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient, complete_with_schema: response)
    end

    it 'extracts the JSON from the prose and parses issues', :aggregate_failures do
      report = reviewer.review
      expect(report.total_issues).to eq(1)
      expect(report.issues.first.title).to eq('Bug')
    end
  end

  context 'when the LLM returns pure prose with no JSON' do
    let(:fake_llm_client) do
      cost_stub = instance_double(RubyLLM::Cost, total: nil)
      response = instance_double(RubyLLM::Message, content: "I'll review this diff carefully.",
                                                   input_tokens: 80, output_tokens: 40, tool_calls: {},
                                                   cache_read_tokens: nil, cache_write_tokens: nil,
                                                   cost: cost_stub,
                                                   thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient, complete_with_schema: response)
    end

    it 'records a warning and returns no issues', :aggregate_failures do
      report = reviewer.review
      expect(report.total_issues).to eq(0)
      expect(report.processing_warnings).to include(/Could not parse LLM response/)
    end
  end

  context 'when debug is enabled' do
    subject(:debug_reviewer) do
      described_class.new(
        config: config,
        changeset: fake_changeset,
        prompt_builder: Thingie::PromptBuilder.new(config),
        llm_client: fake_llm_client,
        debug: true
      )
    end

    it 'prints the pre-review banner with model, provider, and file list' do
      pattern = /
        \[DEBUG\]\ Review\ starting.*\[DEBUG\]\ Model: \ .*Provider: \ .*
        \[DEBUG\]\ Critic\ model: \ .*\[DEBUG\]\ Files\ \(1\):\ app\.rb
      /xm
      expect { debug_reviewer.review }.to output(pattern).to_stderr
    end

    it 'prints the first-pass summary with finding counts and severity distribution' do
      pattern = /
        \[DEBUG\]\ First\ pass:\ 1\ findings.*\[DEBUG\]\ \ \ app\.rb:\ 1.*
        \[DEBUG\]\ \ \ Severity\ distribution:\ severity=2\ ->\ 1
      /xm
      expect { debug_reviewer.review }.to output(pattern).to_stderr
    end

    it 'prints the initial review section header' do
      expect { debug_reviewer.review }.to output(/\[DEBUG\]\ ---\ Initial\ Review\ Pass/).to_stderr
    end

    it 'prints per-call review instrumentation with token counts' do
      pattern = %r{\[DEBUG\]\[REVIEW\]\ app\.rb:\ 1\ issue\(s\)\ found\ \|\ tokens:\ 100\ in\ /\ 50\ out}
      expect { debug_reviewer.review }.to output(pattern).to_stderr
    end

    it 'prints the critic section header' do
      expect { debug_reviewer.review }.to output(/\[DEBUG\]\ ---\ Critic\ Pass\ ---/).to_stderr
    end

    context 'when the critic drops a finding' do
      let(:fake_llm_client) do
        issues = [
          { 'title' => 'keep-me', 'details' => 'd', 'severity' => 2,
            'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] },
          { 'title' => 'drop-me', 'details' => 'd', 'severity' => 3,
            'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }
        ]
        review_cost = instance_double(RubyLLM::Cost, total: 0.000280)
        review_response = instance_double(RubyLLM::Message, content: { 'issues' => issues },
                                                            input_tokens: 200, output_tokens: 80, tool_calls: {},
                                                            cache_read_tokens: nil, cache_write_tokens: nil,
                                                            cost: review_cost, model_info: nil,
                                                            thinking: nil, thinking_tokens: nil)
        instance_double(Thingie::LlmClient).tap do |client|
          allow(client).to receive(:complete_with_schema) do |prompt, *_|
            next review_response unless prompt.to_s.include?('FINDING TO CHALLENGE')

            verdict = prompt.to_s.include?('drop-me') ? 'reject' : 'uphold'
            verdict_cost = instance_double(RubyLLM::Cost, total: 0.000090)
            instance_double(RubyLLM::Message, content: { 'verdict' => verdict, 'reasoning' => 'r' },
                                              input_tokens: 150, output_tokens: 30, tool_calls: {},
                                              cache_read_tokens: nil, cache_write_tokens: nil,
                                              cost: verdict_cost, model_info: nil,
                                              thinking: nil, thinking_tokens: nil)
          end
        end
      end

      it 'prints the critic summary listing the dropped finding' do
        pattern = /
          \[DEBUG\]\ Critic\ pass:\ dropped\ 1\ of\ 2\ findings.*
          \[DEBUG\]\ \ \ DROPPED:\ 'drop-me'\ \(app\.rb,\ severity=3\)
        /xm
        expect { debug_reviewer.review }.to output(pattern).to_stderr
      end

      it 'prints per-call critic instrumentation for upheld findings' do
        expect { debug_reviewer.review }
          .to output(/\[DEBUG\]\[CRITIC\]\ 'keep-me'\ \(app\.rb\)\ ->\ uphold\ \|\ tokens:/).to_stderr
      end

      it 'prints per-call critic instrumentation for rejected findings' do
        expect { debug_reviewer.review }
          .to output(/\[DEBUG\]\[CRITIC\]\ 'drop-me'\ \(app\.rb\)\ ->\ reject\ \|\ tokens:/).to_stderr
      end
    end

    it 'is silent when debug is false' do
      silent_reviewer = described_class.new(
        config: config,
        changeset: fake_changeset,
        prompt_builder: Thingie::PromptBuilder.new(config),
        llm_client: fake_llm_client,
        debug: false
      )
      expect { silent_reviewer.review }.not_to output.to_stderr
    end
  end
end
