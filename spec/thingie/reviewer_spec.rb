# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'benchmark'

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
    instance_double(Thingie::Changeset, patches: [],
                                        files: ['app.rb'],
                                        diff_text_for: "+ def hello\n",
                                        full_content_for: "def hello\nend\n",
                                        changed_lines_for: Set.new([1]),
                                        all?: false,
                                        base_ref: 'main',
                                        head_ref: 'HEAD',
                                        head_sha: 'abc123')
  end
  let(:fake_llm_client) do
    issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
    cost_stub = instance_double(RubyLLM::Cost, total: 0.000150)
    response = message_double(content: { 'issues' => issues },
                              input_tokens: 100, output_tokens: 50, tool_calls: {},
                              cache_read_tokens: nil, cache_write_tokens: nil, cost: cost_stub,
                              model_info: nil, thinking: nil, thinking_tokens: nil)
    verdict = message_double(content: { 'verdict' => 'uphold' },
                             input_tokens: 100, output_tokens: 50, tool_calls: {},
                             cache_read_tokens: nil, cache_write_tokens: nil, cost: cost_stub,
                             model_info: nil, thinking: nil, thinking_tokens: nil)
    instance_double(Thingie::LlmClient).tap do |client|
      allow(client).to receive(:complete_with_schema) do |prompt, *|
        prompt.include?('FINDING TO CHALLENGE') ? verdict : response
      end
    end
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

  context 'when the review pass uses its tools' do
    let(:fake_llm_client) do
      issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                  'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
      response = message_double(content: { 'issues' => issues }, input_tokens: 1, output_tokens: 1, tool_calls: {},
                                cache_read_tokens: nil, cache_write_tokens: nil, cost: nil, model_info: nil,
                                thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |_prompt, _schema, tool_log: nil, **|
          tool_log&.push('thingie--search hello')
          response
        end
      end
    end

    it 'keeps what it asked the tools on each finding from that file' do
      expect(reviewer.review.issues.first.review_tool_calls).to eq(['thingie--search hello'])
    end
  end

  context 'with the default tool budget' do
    let(:seen) { {} }
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, _schema, tool_budget: nil, **|
          seen[:prompt] = prompt
          seen[:budget] = tool_budget
          message_double(content: { 'issues' => [] }, input_tokens: 1, output_tokens: 1, tool_calls: {},
                         cache_read_tokens: nil, cache_write_tokens: nil, cost: nil, model_info: nil,
                         thinking: nil, thinking_tokens: nil)
        end
      end
    end

    it 'gives each file review a budget of 5, and says so only when there are tools', :aggregate_failures do
      reviewer.review

      expect(seen[:budget]).to be_a(Thingie::ToolBudget)
      expect(seen[:budget].limit).to eq(5)
      expect(seen[:prompt]).not_to include('tool calls for this file')

      described_class.new(config: config, changeset: fake_changeset, prompt_builder: Thingie::PromptBuilder.new(config),
                          llm_client: fake_llm_client, tools: [instance_double(RubyLLM::Tool)]).review

      expect(seen[:prompt]).to include('at most 5 tool calls for this file')
    end
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

  context 'when deciding whether to tell the model about the symbol lookup tool' do
    let(:prompts) { [] }
    let(:fake_llm_client) do
      response = message_double(content: { 'issues' => [] }, input_tokens: 1, output_tokens: 1, tool_calls: {},
                                cache_read_tokens: nil, cache_write_tokens: nil, cost: nil, model_info: nil,
                                thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) { |prompt, *_| (prompts << prompt) && response }
      end
    end
    let(:file_tool) { Thingie::FileTool.new(root: tmp_dir) }
    let(:symbol_tool) { Thingie::Lsp::SymbolTool.new(client: instance_double(Thingie::Lsp::Client), root: tmp_dir) }

    def first_prompt_with(tools)
      described_class.new(config: config, changeset: fake_changeset, llm_client: fake_llm_client, tools: tools,
                          prompt_builder: Thingie::PromptBuilder.new(config)).review
      prompts.first
    end

    it 'does not mention it when the only tools read and search files' do
      expect(first_prompt_with([file_tool])).not_to include('symbol lookup')
    end

    it 'mentions it when the symbol tool is there' do
      expect(first_prompt_with([file_tool, symbol_tool])).to include('symbol lookup')
    end
  end

  context 'when an issue falls on an unchanged line' do
    let(:fake_changeset) do
      instance_double(Thingie::Changeset, patches: [],
                                          files: ['app.rb'],
                                          diff_text_for: "+ def hello\n",
                                          full_content_for: "def hello\nend\n",
                                          changed_lines_for: Set.new([5]), # issue is on line 1, not changed
                                          all?: false,
                                          base_ref: 'main',
                                          head_ref: 'HEAD',
                                          head_sha: 'abc123')
    end

    it 'drops findings outside the changed lines' do
      expect(reviewer.review.total_issues).to eq(0)
    end
  end

  context 'when the PR touches other files' do
    include GitRepo

    let(:repo) { Dir.mktmpdir }
    let(:fake_changeset) do
      git(repo, 'init', '-q', '-b', 'main')
      git_commit(repo, 'base')
      git(repo, 'tag', 'base')
      git_write(repo, 'app/granola_gated.rb', "class GranolaGated\nend\n")
      git_write(repo, 'app.rb', "GranolaGated.new\n")
      git_commit(repo, 'head')
      Thingie::Changeset.new(repo_path: repo, base_ref: 'base', filters: ['app.rb'])
    end
    let(:prompts) { [] }
    let(:fake_llm_client) do
      response = message_double(content: { 'issues' => [] }, input_tokens: 1, output_tokens: 1, tool_calls: {},
                                cache_read_tokens: nil, cache_write_tokens: nil, cost: nil, model_info: nil,
                                thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) { |prompt, *| (prompts << prompt) && response }
      end
    end

    after { FileUtils.rm_rf(repo) }

    it 'lists them in the review prompt' do
      reviewer.review
      expect(prompts.first).to include('----OTHER CHANGES IN THIS PR----', '- added app/granola_gated.rb')
    end

    context 'when a spec and the code it tests both change' do
      let(:fake_changeset) do
        git(repo, 'init', '-q', '-b', 'main')
        git_write(repo, 'app/lib/deliver.rb', "class Deliver\nend\n")
        git_write(repo, 'spec/lib/deliver_spec.rb', "RSpec.describe Deliver do\nend\n")
        git_commit(repo, 'base')
        git(repo, 'tag', 'base')
        git_write(repo, 'app/lib/deliver.rb', "class Deliver\n  def call = true\nend\n")
        git_write(repo, 'spec/lib/deliver_spec.rb', "RSpec.describe Deliver do\n  it 'calls' do\n  end\nend\n")
        git_commit(repo, 'head')
        Thingie::Changeset.new(repo_path: repo, base_ref: 'base')
      end

      it 'shows each the other in its review prompt', :aggregate_failures do
        reviewer.review
        spec_prompt = prompts.find { |prompt| prompt.include?("TO REVIEW----\ndiff --git a/spec/lib/deliver_spec.rb") }
        code_prompt = prompts.find { |prompt| prompt.include?("TO REVIEW----\ndiff --git a/app/lib/deliver.rb") }
        expect(spec_prompt).to include('----RELATED FILE----', 'The code these tests exercise: app/lib/deliver.rb')
        expect(code_prompt).to include('----RELATED FILE----',
                                       'The tests for this file, changed in this PR: spec/lib/deliver_spec.rb')
      end
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

    it 'aborts when every file failed instead of silently returning no issues' do
      expect do
        reviewer.review
      end.to raise_error(RuntimeError, /All 1 file reviews failed.*Failed to open TCP connection/m)
    end
  end

  context 'when the LLM client fails on only some files' do
    let(:fake_changeset) do
      instance_double(Thingie::Changeset).tap do |changeset|
        allow(changeset).to receive_messages(files: ['app.rb', 'other.rb'], patches: [],
                                             changed_lines_for: Set.new([1]), all?: false,
                                             base_ref: 'main', head_ref: 'HEAD', head_sha: 'abc123')
        allow(changeset).to receive(:diff_text_for) { |file| file == 'other.rb' ? "+ def other\n" : "+ def hello\n" }
        allow(changeset).to receive(:full_content_for) { |file|
          "#{file == 'other.rb' ? 'def other' : 'def hello'}\nend\n"
        }
      end
    end
    let(:connection_error) { Class.new(StandardError) }
    let(:fake_llm_client) do
      issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                  'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
      response = message_double(content: { 'issues' => issues },
                                input_tokens: 100, output_tokens: 50, tool_calls: {},
                                cache_read_tokens: nil, cache_write_tokens: nil,
                                cost: instance_double(RubyLLM::Cost, total: nil),
                                thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, _schema, _tools|
          raise connection_error, 'Rate limit exceeded' if prompt.include?('def other')

          response
        end
      end
    end

    it 'skips the failed file with a warning, lists it as unreviewed, and reviews the rest', :aggregate_failures do
      report = reviewer.review
      expect(report.total_issues).to eq(1)
      expect(report.processing_warnings).to include(/Failed to review other.rb: .*Rate limit exceeded/)
      expect(report.unreviewed_files).to eq(['other.rb'])
      expect(report.number_of_processed_files).to eq(2)
    end
  end

  context 'when one file takes longer than the time limit' do
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { 'call_timeout' => 0.05 }) }
    let(:fake_changeset) do
      instance_double(Thingie::Changeset).tap do |changeset|
        allow(changeset).to receive_messages(files: ['app.rb', 'other.rb'], patches: [],
                                             changed_lines_for: Set.new([1]), all?: false,
                                             base_ref: 'main', head_ref: 'HEAD', head_sha: 'abc123')
        allow(changeset).to receive(:diff_text_for) { |file| file == 'other.rb' ? "+ def other\n" : "+ def hello\n" }
        allow(changeset).to receive(:full_content_for) { |file|
          "#{file == 'other.rb' ? 'def other' : 'def hello'}\nend\n"
        }
      end
    end
    let(:fake_llm_client) do
      issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                  'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
      response = message_double(content: { 'issues' => issues },
                                input_tokens: 100, output_tokens: 50, tool_calls: {},
                                cache_read_tokens: nil, cache_write_tokens: nil,
                                cost: instance_double(RubyLLM::Cost, total: nil),
                                thinking: nil, thinking_tokens: nil)
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, _schema, _tools|
          sleep(5) if prompt.include?('def other')

          response
        end
      end
    end

    it 'tries that file once more, then gives up on it with a warning and reviews the rest', :aggregate_failures do
      report = nil
      elapsed = Benchmark.realtime { report = reviewer.review }

      expect(report.total_issues).to eq(1)
      expect(fake_llm_client).to have_received(:complete_with_schema).with(/def other/, any_args).twice
      expect(report.processing_warnings).to include(/Retried the review of other.rb after Async::TimeoutError/)
      expect(report.processing_warnings).to include(/Failed to review other.rb: .*TimeoutError/)
      expect(report.unreviewed_files).to eq(['other.rb'])
      expect(elapsed).to be < 2
    end
  end

  context 'when a review call fails' do
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { 'call_timeout' => 0.05 }) }
    let(:review_prompts) { [] }
    let(:fake_llm_client) do
      issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                  'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
      cost_stub = instance_double(RubyLLM::Cost, total: nil)
      reply = lambda do |content|
        message_double(content: content, input_tokens: nil, output_tokens: nil, tool_calls: {},
                       cache_read_tokens: nil, cache_write_tokens: nil, cost: cost_stub,
                       model_info: nil, thinking: nil, thinking_tokens: nil)
      end
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, *|
          next reply.call({ 'verdict' => 'uphold' }) if prompt.include?('FINDING TO CHALLENGE')

          review_prompts << prompt
          case (failure = failures.shift)
          when :timeout then sleep(5)
          when :no_json then next reply.call('not valid json')
          when Exception then raise failure
          end
          reply.call({ 'issues' => issues })
        end
      end
    end

    context 'when the first call times out and the second answers' do
      let(:failures) { [:timeout] }

      it 'tries again and reviews the file', :aggregate_failures do
        report = reviewer.review

        expect(review_prompts.size).to eq(2)
        expect(report.total_issues).to eq(1)
        expect(report.unreviewed_files).to be_empty
        expect(report.processing_warnings).to include(/Retried the review of app.rb after Async::TimeoutError/)
      end
    end

    context 'when the provider is overloaded on the first call' do
      let(:failures) { [RubyLLM::OverloadedError.new('Overloaded')] }

      it 'tries again and reviews the file', :aggregate_failures do
        report = reviewer.review

        expect(report.total_issues).to eq(1)
        expect(report.processing_warnings).to include(/Retried the review of app.rb after RubyLLM::OverloadedError/)
      end
    end

    context 'when the connection fails on the first call' do
      let(:failures) { [Faraday::ConnectionFailed.new('Failed to open TCP connection')] }

      it 'tries again and reviews the file', :aggregate_failures do
        report = reviewer.review

        expect(report.total_issues).to eq(1)
        expect(report.processing_warnings).to include(/Retried the review of app.rb after Faraday::ConnectionFailed/)
      end
    end

    context 'when the first reply has no JSON and the second call times out' do
      let(:failures) { %i[no_json timeout] }

      it 'gives up after the second call' do
        expect { reviewer.review }.to raise_error(RuntimeError, /All 1 file reviews failed.*TimeoutError/m)
        expect(review_prompts.size).to eq(2)
      end
    end

    context 'when the API key is rejected' do
      let(:failures) { [RubyLLM::UnauthorizedError.new('Invalid API key')] }

      it 'does not try again' do
        expect { reviewer.review }.to raise_error(RuntimeError, /All 1 file reviews failed.*Invalid API key/m)
        expect(review_prompts.size).to eq(1)
      end
    end
  end

  context 'when one file finishes its review while another is still being reviewed' do
    let(:events) { [] }
    let(:fake_changeset) do
      instance_double(Thingie::Changeset).tap do |changeset|
        allow(changeset).to receive_messages(files: ['slow.rb', 'app.rb'], patches: [],
                                             changed_lines_for: Set.new([1]), all?: false,
                                             base_ref: 'main', head_ref: 'HEAD', head_sha: 'abc123')
        allow(changeset).to receive(:diff_text_for) { |file| file == 'slow.rb' ? "+ def slow\n" : "+ def hello\n" }
        allow(changeset).to receive(:full_content_for) { |file|
          "#{file == 'slow.rb' ? 'def slow' : 'def hello'}\nend\n"
        }
      end
    end
    let(:fake_llm_client) do
      issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                  'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
      reply = lambda do |content|
        message_double(content: content, input_tokens: nil, output_tokens: nil, tool_calls: {},
                       cache_read_tokens: nil, cache_write_tokens: nil,
                       cost: instance_double(RubyLLM::Cost, total: nil),
                       model_info: nil, thinking: nil, thinking_tokens: nil)
      end
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, *|
          if prompt.include?('FINDING TO CHALLENGE')
            events << :critic_started
            reply.call({ 'verdict' => 'uphold' })
          elsif prompt.include?('def slow')
            sleep(0.2)
            events << :slow_review_finished
            reply.call({ 'issues' => [] })
          else
            reply.call({ 'issues' => issues })
          end
        end
      end
    end

    it "checks the finished file's findings without waiting for the slow file", :aggregate_failures do
      report = reviewer.review

      expect(events).to eq(%i[critic_started slow_review_finished])
      expect(report.issues.map(&:file)).to eq(['app.rb'])
    end
  end

  context 'when reviews and critic checks share max_concurrent_tasks' do
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { 'max_concurrent_tasks' => 1 }) }
    let(:in_flight) { { now: 0, peak: 0 } }
    let(:fake_changeset) do
      instance_double(Thingie::Changeset).tap do |changeset|
        allow(changeset).to receive_messages(files: ['app.rb', 'other.rb'], patches: [],
                                             changed_lines_for: Set.new([1]), all?: false,
                                             base_ref: 'main', head_ref: 'HEAD', head_sha: 'abc123')
        allow(changeset).to receive(:diff_text_for) { |file| "+ #{file}\n" }
        allow(changeset).to receive(:full_content_for) { |file| "#{file}\nend\n" }
      end
    end
    let(:fake_llm_client) do
      issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                  'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, *|
          in_flight[:now] += 1
          in_flight[:peak] = [in_flight[:peak], in_flight[:now]].max
          sleep(0.01)
          in_flight[:now] -= 1
          content = prompt.include?('FINDING TO CHALLENGE') ? { 'verdict' => 'uphold' } : { 'issues' => issues }
          message_double(content: content, input_tokens: nil, output_tokens: nil, tool_calls: {},
                         cache_read_tokens: nil, cache_write_tokens: nil,
                         cost: instance_double(RubyLLM::Cost, total: nil),
                         model_info: nil, thinking: nil, thinking_tokens: nil)
        end
      end
    end

    it 'never runs more LLM calls at once than the limit', :aggregate_failures do
      report = reviewer.review

      expect(in_flight[:peak]).to eq(1)
      expect(report.issues.map(&:file)).to eq(['app.rb', 'other.rb'])
    end
  end

  context 'when reviewing the whole codebase' do
    let(:fake_changeset) do
      instance_double(Thingie::Changeset, patches: [],
                                          files: ['app.rb'],
                                          diff_text_for: "def hello\nend\n",
                                          full_content_for: "def hello\nend\n",
                                          changed_lines_for: nil,
                                          all?: true,
                                          base_ref: 'main',
                                          head_ref: 'HEAD',
                                          head_sha: 'abc123')
    end
    let(:prompt_builder) do
      builder = Thingie::PromptBuilder.new(config)
      allow(builder).to receive(:review).and_return('prompt')
      builder
    end

    before do
      allow(Thingie::PromptBuilder).to receive(:new).and_return(prompt_builder)
    end

    it 'marks the prompt as whole-file and does not duplicate the content' do
      reviewer.review
      expect(prompt_builder).to have_received(:review)
        .with(diff: "def hello\nend\n", file_lines: nil, symbol_lookup: false, whole_file: true, pr_context: '',
              companion: '', tool_budget: nil)
    end
  end

  context 'when a changed file contains obfuscated code' do
    let(:hex_blob) { ObfuscationSamples::HEX_BLOB }
    let(:fake_changeset) do
      instance_double(Thingie::Changeset, patches: [],
                                          files: ['app.rb'],
                                          diff_text_for: "+ def hello\n",
                                          full_content_for: "def hello\nend\npayload = '#{hex_blob}'\n",
                                          changed_lines_for: Set.new([1]),
                                          all?: false,
                                          base_ref: 'main',
                                          head_ref: 'HEAD',
                                          head_sha: 'abc123')
    end

    it 'adds the obfuscation finding alongside the LLM findings', :aggregate_failures do
      report = reviewer.review
      obfuscation_issues = report.issues.select { |issue| issue.tags.include?('obfuscation') }
      expect(obfuscation_issues.size).to eq(1)
      expect(obfuscation_issues.first.file).to eq('app.rb')
      expect(obfuscation_issues.first.severity).to eq(1)
      # LLM finding on the changed line is still present.
      expect(report.issues.map(&:title)).to include('Missing return')
      expect(report.total_issues).to eq(2)
    end

    it 'flags obfuscation even when it sits on an unchanged line' do
      allow(fake_changeset).to receive(:changed_lines_for).and_return(Set.new([1]))
      report = reviewer.review
      expect(report.issues.any? { |issue| issue.tags.include?('obfuscation') }).to be true
    end

    it 'assigns ids across LLM and scanner findings' do
      report = reviewer.review
      expect(report.issues.map(&:id).sort).to eq([1, 2])
    end
  end

  context 'when no obfuscation is present' do
    it 'does not add scanner findings' do
      report = reviewer.review
      expect(report.issues.none? { |issue| issue.tags.include?('obfuscation') }).to be true
    end
  end

  context 'when the LLM returns malformed JSON' do
    let(:fake_llm_client) do
      response = message_double(content: 'not valid json',
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

  context 'when the critic upholds a finding at a confidence past max_confidence' do
    let(:config) { Thingie::Configuration.new(root: tmp_dir, overrides: { 'post_process' => { 'max_confidence' => 2 } }) }
    let(:fake_llm_client) do
      issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                  'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
      reply = lambda do |content|
        message_double(content: content, input_tokens: nil, output_tokens: nil, tool_calls: {},
                       cache_read_tokens: nil, cache_write_tokens: nil,
                       cost: instance_double(RubyLLM::Cost, total: nil),
                       model_info: nil, thinking: nil, thinking_tokens: nil)
      end
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, *|
          if prompt.include?('FINDING TO CHALLENGE')
            reply.call({ 'verdict' => 'uphold', 'confidence_override' => 3 })
          else
            reply.call({ 'issues' => issues })
          end
        end
      end
    end

    it 'holds it back in the report instead of dropping it', :aggregate_failures do
      report = reviewer.review

      expect(report.issues).to be_empty
      expect(report.held_back_issues.map(&:title)).to eq(['Missing return'])
    end
  end

  context 'when System One rated the file trivial' do
    subject(:reviewer) do
      described_class.new(config: config, changeset: fake_changeset, prompt_builder: Thingie::PromptBuilder.new(config),
                          llm_client: fake_llm_client, file_ratings: { 'app.rb' => 'trivial' })
    end

    it 'holds back an upheld finding that is not Critical', :aggregate_failures do
      report = reviewer.review

      expect(report.issues).to be_empty
      expect(report.held_back_issues.map(&:title)).to eq(['Missing return'])
    end
  end

  context 'when the first reply has no JSON and the second does' do
    let(:fake_llm_client) do
      issues = [{ 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                  'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }]
      cost_stub = instance_double(RubyLLM::Cost, total: nil)
      reply = lambda do |content|
        message_double(content: content, input_tokens: nil, output_tokens: nil, tool_calls: {},
                       cache_read_tokens: nil, cache_write_tokens: nil, cost: cost_stub,
                       model_info: nil, thinking: nil, thinking_tokens: nil)
      end
      replies = [reply.call('not valid json'), reply.call({ 'issues' => issues })]
      verdict = reply.call({ 'verdict' => 'uphold' })
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, *|
          prompt.include?('FINDING TO CHALLENGE') ? verdict : replies.shift
        end
      end
    end

    it 'asks again and reviews the file', :aggregate_failures do
      report = reviewer.review

      expect(report.total_issues).to eq(1)
      expect(report.unreviewed_files).to be_empty
      expect(report.processing_warnings).to include(/Retried the review of app.rb after JSON::ParserError/)
    end
  end

  context 'when a review reply has no JSON and the same chat can be asked again' do
    let(:review_prompts) { [] }
    let(:chat) { double('chat') } # rubocop:disable RSpec/VerifiedDoubles
    let(:reply) do
      cost_stub = instance_double(RubyLLM::Cost, total: nil)
      lambda do |content|
        message_double(content: content, input_tokens: nil, output_tokens: nil, tool_calls: {},
                       cache_read_tokens: nil, cache_write_tokens: nil, cost: cost_stub,
                       model_info: nil, thinking: nil, thinking_tokens: nil)
      end
    end
    let(:issues_reply) do
      issue = { 'title' => 'Missing return', 'details' => 'No return value', 'severity' => 2,
                'confidence' => 1, 'tags' => ['bug'], 'affected_lines' => [{ 'start_line' => 1 }] }
      reply.call({ 'issues' => [issue] })
    end
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient).tap do |client|
        allow(client).to receive(:complete_with_schema) do |prompt, _schema, chats: nil, **|
          next reply.call({ 'verdict' => 'uphold' }) if prompt.include?('FINDING TO CHALLENGE')

          review_prompts << prompt
          chats << chat
          review_replies.shift
        end
      end
    end

    before { allow(chat).to receive(:ask).with(described_class::ISSUES_ONLY).and_return(*follow_ups) }

    context 'when the follow-up has the JSON' do
      let(:review_replies) { [reply.call('Looks like a missing return.')] }
      let(:follow_ups) { [issues_reply] }

      it 'reviews the file without reviewing it again', :aggregate_failures do
        report = reviewer.review

        expect(report.total_issues).to eq(1)
        expect(report.unreviewed_files).to be_empty
        expect(review_prompts.size).to eq(1)
        expect(chat).to have_received(:ask).once
        expect(report.processing_warnings).to eq(
          ['Asked again for the review JSON of app.rb after no valid JSON found in response']
        )
      end
    end

    context 'when the follow-up has no JSON either' do
      let(:review_replies) { [reply.call('Looks like a missing return.'), issues_reply] }
      let(:follow_ups) { [reply.call('Still prose.')] }

      it 'reviews the file again', :aggregate_failures do
        report = reviewer.review

        expect(report.total_issues).to eq(1)
        expect(review_prompts.size).to eq(2)
        expect(report.processing_warnings).to include(/Asked again for the review JSON of app.rb/,
                                                      /Retried the review of app.rb after JSON::ParserError/)
      end
    end

    context 'when neither review nor either follow-up has JSON' do
      let(:review_replies) { [reply.call('Prose.'), reply.call('More prose.')] }
      let(:follow_ups) { [reply.call('Still prose.'), reply.call('Prose again.')] }

      it 'reviews the file at most twice, then leaves it unreviewed', :aggregate_failures do
        report = reviewer.review

        expect(review_prompts.size).to eq(2)
        expect(chat).to have_received(:ask).twice
        expect(report.unreviewed_files).to eq(['app.rb'])
        expect(report.processing_warnings).to include(/Could not parse LLM response for app.rb/)
      end
    end
  end

  context 'when the LLM returns a nil response' do
    let(:fake_llm_client) do
      instance_double(Thingie::LlmClient, complete_with_schema: nil)
    end

    it 'treats the file as unreviewed, with a warning, not as having no issues', :aggregate_failures do
      report = reviewer.review

      expect(report.total_issues).to eq(0)
      expect(report.unreviewed_files).to eq(['app.rb'])
      expect(report.processing_warnings).to include(/Could not parse LLM response for app.rb: the reply is empty/)
    end
  end

  context 'when the LLM returns a response with nil content' do
    let(:fake_llm_client) do
      response = message_double(content: nil,
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
      response = message_double(content: json,
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
      response = message_double(content: prose,
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

  context 'when the model answers in the reasoning channel and leaves the content empty' do
    let(:thinking) do
      '{"issues":[{"title":"Bug","details":"desc","severity":1,"confidence":1,' \
        '"tags":[],"affected_lines":[{"start_line":1}]}]}'
    end
    let(:fake_llm_client) do
      response = message_double(content: '', input_tokens: 80, output_tokens: 40, tool_calls: {},
                                cache_read_tokens: nil, cache_write_tokens: nil,
                                cost: instance_double(RubyLLM::Cost, total: nil),
                                thinking: instance_double(RubyLLM::Thinking, text: thinking), thinking_tokens: nil)
      instance_double(Thingie::LlmClient, complete_with_schema: response)
    end

    it 'parses the findings from the reasoning', :aggregate_failures do
      report = reviewer.review
      expect(report.total_issues).to eq(1)
      expect(report.issues.first.title).to eq('Bug')
    end

    context 'when the reasoning is prose without an issues object' do
      let(:thinking) { 'Checking the diff. A hash like {"a": 1} is fine here.' }

      it 'reports no issues and no warning', :aggregate_failures do
        report = reviewer.review
        expect(report.total_issues).to eq(0)
        expect(report.processing_warnings).to be_empty
      end
    end

    context 'when an unrelated object is quoted before the issues object' do
      let(:thinking) do
        'The diff changes {"a": 1}. Answer: {"issues":[{"title":"Bug","details":"desc","severity":1,' \
          '"confidence":1,"tags":[],"affected_lines":[{"start_line":1}]}]}'
      end

      it 'still finds the issues' do
        expect(reviewer.review.total_issues).to eq(1)
      end
    end

    context 'when a draft issues object is quoted before the final answer' do
      let(:thinking) do
        'Draft: {"issues":[]}. Final: {"issues":[{"title":"Bug","details":"desc","severity":1,' \
          '"confidence":1,"tags":[],"affected_lines":[{"start_line":1}]}]}'
      end

      it 'uses the final answer' do
        expect(reviewer.review.total_issues).to eq(1)
      end
    end
  end

  context 'when the LLM returns pure prose with no JSON' do
    let(:fake_llm_client) do
      cost_stub = instance_double(RubyLLM::Cost, total: nil)
      response = message_double(content: "I'll review this diff carefully.",
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
        review_response = message_double(content: { 'issues' => issues },
                                         input_tokens: 200, output_tokens: 80, tool_calls: {},
                                         cache_read_tokens: nil, cache_write_tokens: nil,
                                         cost: review_cost, model_info: nil,
                                         thinking: nil, thinking_tokens: nil)
        instance_double(Thingie::LlmClient).tap do |client|
          allow(client).to receive(:complete_with_schema) do |prompt, *_|
            next review_response unless prompt.to_s.include?('FINDING TO CHALLENGE')

            verdict = prompt.to_s.include?('drop-me') ? 'reject' : 'uphold'
            verdict_cost = instance_double(RubyLLM::Cost, total: 0.000090)
            message_double(content: { 'verdict' => verdict, 'reasoning' => 'r' },
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
