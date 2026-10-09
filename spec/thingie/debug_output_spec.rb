# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::DebugOutput do
  subject(:debug_output) { described_class.new(config: config, changeset: changeset, enabled: true) }

  let(:config) { Thingie::Configuration.new(root: Dir.mktmpdir) }
  let(:changeset) { instance_double(Thingie::Changeset, files: ['app.rb']) }

  def response(input:, output:, context_window: nil, thinking: nil, thinking_tokens: nil, content: nil)
    model_info = context_window ? instance_double(model_info_class, context_window: context_window) : nil
    cost = instance_double(RubyLLM::Cost, total: 0.0001)
    message_double(input_tokens: input, output_tokens: output, tool_calls: {},
                   cache_read_tokens: nil, cache_write_tokens: nil, cost: cost,
                   model_info: model_info, thinking: thinking,
                   thinking_tokens: thinking_tokens, content: content)
  end

  def issue(title: 'Test issue', severity: 2, confidence: 1, tags: ['bug'], file: 'app.rb')
    Thingie::Issue.from_hash('title' => title, 'details' => 'd', 'severity' => severity,
                             'confidence' => confidence, 'tags' => tags, 'file' => file,
                             'affected_lines' => [{ 'start_line' => 1 }])
  end

  describe '#review_call' do
    it 'names the provider that served the call when the gateway reports one' do
      raw = instance_double(Faraday::Response, body: { 'provider' => 'DeepInfra' })
      served = message_double(content: nil, input_tokens: 1, output_tokens: 1, tool_calls: {}, cache_read_tokens: nil,
                              cache_write_tokens: nil, cost: nil, model_info: nil, thinking: nil, thinking_tokens: nil,
                              raw: raw)

      expect { debug_output.review_call(file: 'app.rb', response: served, issues: []) }
        .to output(/app\.rb: 0 issue\(s\) found \| .*via DeepInfra/).to_stderr
    end

    it 'includes context-window usage when the model info is available' do
      resp = response(input: 1000, output: 500, context_window: 10_000)

      expect do
        debug_output.review_call(file: 'app.rb', response: resp, issues: [])
      end.to output(%r{1500/10000 ctx \(15\.0%\)}).to_stderr
    end

    it 'omits context-window usage when the model info is unavailable' do
      resp = response(input: 1000, output: 500)

      expect do
        debug_output.review_call(file: 'app.rb', response: resp, issues: [])
      end.not_to output(/ctx/).to_stderr
    end

    it 'prints per-issue detail lines for parsed findings' do
      resp = response(input: 100, output: 50, content: { 'issues' => [] })
      issues = [issue(title: 'Missing return'), issue(title: 'Bad naming', severity: 3, tags: ['naming'])]

      expect do
        debug_output.review_call(file: 'app.rb', response: resp, issues: issues)
      end.to output(/\[DEBUG\]\[REVIEW\]\s+1\.\ \[sev=2\ conf=1\]\ bug:\ Missing\ return/).to_stderr
    end

    it 'prints the raw response content when available' do
      resp = response(input: 100, output: 50, content: { 'issues' => [] })

      expect do
        debug_output.review_call(file: 'app.rb', response: resp, issues: [])
      end.to output(/response content:/).to_stderr
    end

    it 'prints reasoning/thinking output when the provider returns it' do
      resp = response(input: 100, output: 50, thinking: 'Step 1: analyze\nStep 2: conclude',
                      thinking_tokens: 42, content: { 'issues' => [] })

      expect do
        debug_output.review_call(file: 'app.rb', response: resp, issues: [])
      end.to output(/\[DEBUG\]\[REVIEW\]\s+reasoning\ \(42\ tokens\):/).to_stderr
    end
  end

  describe '#tool_calls' do
    subject(:debug) { described_class.new(config: config, changeset: changeset, enabled: true) }

    it 'names the tools a call used and how many times', :aggregate_failures do
      names = %w[thingie--search thingie--file thingie--search]
      expect { debug.tool_calls(tag: 'REVIEW', label: 'app.rb', names: names) }
        .to output("[DEBUG][REVIEW] app.rb: tool calls: thingie--search x2, thingie--file x1\n").to_stderr
    end

    it 'says when a call used none' do
      expect { debug.tool_calls(tag: 'CRITIC', label: 'Leaky query', names: []) }
        .to output("[DEBUG][CRITIC] Leaky query: tool calls: none\n").to_stderr
    end
  end

  describe '#review_error' do
    it 'prints the error class and message' do
      error = JSON::ParserError.new('unexpected token')

      expect do
        debug_output.review_error(file: 'app.rb', error: error)
      end.to output(/\[DEBUG\]\[REVIEW\]\ ERROR\ app\.rb:\ JSON::ParserError:/).to_stderr
    end
  end

  describe '#post_process' do
    it 'prints the before/after counts and dropped count' do
      expect do
        debug_output.post_process(before: 10, after: 7)
      end.to output(/\[DEBUG\]\ Post-process:\ 10\ ->\ 7\ findings\ \(dropped\ 3/).to_stderr
    end
  end

  describe '#critic_call' do
    it 'prints the verdict and token summary' do
      resp = response(input: 200, output: 80, content: { 'verdict' => 'uphold' })

      expect do
        debug_output.critic_call(issue: issue, response: resp, verdict: 'uphold',
                                 content: { 'verdict' => 'uphold' })
      end.to output(/\[DEBUG\]\[CRITIC\]\ 'Test\ issue'\ \(app\.rb\)\ ->\ uphold\ \|\ tokens:/).to_stderr
    end

    it 'prints critic reasoning when the verdict content includes it' do
      resp = response(input: 200, output: 80, content: { 'verdict' => 'reject', 'reasoning' => 'Not a bug' })

      expect do
        debug_output.critic_call(issue: issue, response: resp, verdict: 'reject',
                                 content: { 'verdict' => 'reject', 'reasoning' => 'Not a bug' })
      end.to output(/\[DEBUG\]\[CRITIC\]\s+critic\ reasoning:/).to_stderr
    end

    it 'prints severity/confidence overrides when present' do
      resp = response(input: 200, output: 80, content: {})
      content = { 'verdict' => 'uphold', 'severity_override' => 1, 'confidence_override' => 2 }

      expect do
        debug_output.critic_call(issue: issue, response: resp, verdict: 'uphold', content: content)
      end.to output(/severity_override:\ 1\ \| confidence_override:\ 2/).to_stderr
    end
  end

  describe '#critic_error' do
    it 'prints the error class and message for the failed finding' do
      error = StandardError.new('boom')

      expect do
        debug_output.critic_error(issue: issue, error: error)
      end.to output(/\[DEBUG\]\[CRITIC\]\ ERROR\ 'Test\ issue'\ \(app\.rb\):\ StandardError:\ boom/).to_stderr
    end
  end

  describe '#warnings' do
    it 'prints numbered warnings when present' do
      expect do
        debug_output.warnings(['Parse failed for app.rb', 'Critic error for foo.rb'])
      end.to output(/\[DEBUG\]\ Warnings\ \(2\):.*1\.\ Parse\ failed.*2\.\ Critic\ error/m).to_stderr
    end

    it 'prints nothing when warnings are empty' do
      expect do
        debug_output.warnings([])
      end.not_to output.to_stderr
    end
  end
end
