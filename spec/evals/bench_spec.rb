# frozen_string_literal: true

require 'spec_helper'
require_relative '../../evals/bench/lib/bench'

RSpec.describe Bench do
  def label(kind, title = kind, **extra)
    { 'title' => title, 'file' => 'app/lib/x.rb', 'label' => kind }.merge(extra)
  end

  def finding(label, severity: 3, confidence: 1, unchecked: false)
    { 'title' => 't', 'file' => 'app/lib/x.rb', 'severity' => severity, 'confidence' => confidence,
      'unchecked' => unchecked, 'label' => label }
  end

  let(:real_a) { label('real', 'a') }
  let(:real_b) { label('real', 'b') }
  let(:nit) { label('nit') }
  let(:wrong) { label('wrong') }
  let(:labels) { [real_a, real_b, nit, wrong] }
  let(:usage) { { 'cost_usd' => 1.234, 'input_tokens' => 1000, 'output_tokens' => 50 } }

  describe '.overrides' do
    let(:dir) { Dir.mktmpdir }

    before do
      File.write(File.join(dir, 'config.toml'), "model = \"a\"\n[verify]\nenabled = true\nmodel = \"b\"\n")
      FileUtils.mkdir_p(File.join(dir, 'variants'))
      File.write(File.join(dir, 'variants', 'critic.toml'), "[verify]\nmodel = \"c\"\n")
    end

    after { FileUtils.rm_rf(dir) }

    it 'lays the variant over the pinned config a section at a time' do
      overrides = described_class.overrides('critic', pinned: File.join(dir, 'config.toml'),
                                                      variants: File.join(dir, 'variants'))
      expect(overrides).to eq('model' => 'a', 'verify' => { 'enabled' => true, 'model' => 'c' })
    end
  end

  describe Bench::Case do
    include GitRepo

    let(:root) { Dir.mktmpdir }
    let(:app) { File.join(root, 'app') }
    let(:case_dir) { File.join(root, 'cases', 'escrow') }

    before do
      stub_const('Bench::ROOT', root)
      stub_const('Bench::APP', app)
      FileUtils.mkdir_p(app)
      File.write(File.join(app, 'keep.rb'), "class Keep\nend\n")
      File.write(File.join(app, 'gone.rb'), "class Gone\nend\n")
      FileUtils.mkdir_p(File.join(case_dir, 'final-push'))
      FileUtils.mkdir_p(File.join(case_dir, 'first-push'))
      File.write(File.join(case_dir, 'final-push', 'keep.rb'), "class Keep\n  def call = true\nend\n")
      File.write(File.join(case_dir, 'first-push', 'keep.rb'), "class Keep\n  def call = nil\nend\n")
      File.write(File.join(root, 'config.toml'), "model = \"m\"\n")
      File.write(File.join(case_dir, 'case.yml'), <<~YAML)
        title: Escrow
        body: Reserve points.
        delete: [gone.rb]
        labels:
          - { title: fixed by the final push, file: keep.rb, label: real, push: first, note: n }
          - { title: still there, file: keep.rb, label: real, push: both, note: n }
          - { title: new in the final push, file: keep.rb, label: real, push: final, note: n }
          - { title: a nit, file: keep.rb, label: nit, note: n }
      YAML
    end

    after { FileUtils.rm_rf(root) }

    it 'scores each push against the defects present at it, a label with no push counting at both' do
      kase = described_class.load('escrow')
      expect(kase.labels_at('final-push').map do |l|
        l['title']
      end).to eq(['still there', 'new in the final push', 'a nit'])
      expect(kase.labels_at('first-push').map do |l|
        l['title']
      end).to eq(['fixed by the final push', 'still there', 'a nit'])
    end

    it 'builds base, first-push and final-push commits from the app and the overlays, honouring delete',
       :aggregate_failures do
      repo = described_class.load('escrow').build(File.join(root, 'config.toml'))
      show = ->(*args) { IO.popen(['git', '-C', repo, *args], &:read) }
      tree = ->(tag) { show.call('ls-tree', '-r', '--name-only', tag).split("\n").grep_v(/\A\.thingie/) }
      expect(tree.call('pr-base')).to contain_exactly('gone.rb', 'keep.rb')
      expect(tree.call('pr-first-push')).to contain_exactly('gone.rb', 'keep.rb')
      expect(tree.call('pr-final-push')).to contain_exactly('keep.rb')
      expect(show.call('show', 'pr-first-push:keep.rb')).to include('def call = nil')
      expect(show.call('show', 'pr-final-push:keep.rb')).to include('def call = true')
      expect(File.read(File.join(repo, '.thingie', 'config.toml'))).to eq("model = \"m\"\n")
    end

    it 'rejects a case name that could leave the cases directory' do
      expect { described_class.load('../app') }.to raise_error(ArgumentError, /case name/)
    end

    it 'rejects a label at the first push when the case has no first-push overlay' do
      FileUtils.rm_rf(File.join(case_dir, 'first-push'))
      expect { described_class.load('escrow') }.to raise_error(ArgumentError, /no first-push/)
    end

    it 'rejects a delete path that could leave the repo' do
      File.write(File.join(case_dir, 'case.yml'), "title: t\nbody: b\ndelete: ['../x']\nlabels: []\n")
      expect { described_class.load('escrow').build(File.join(root, 'config.toml')) }
        .to raise_error(ArgumentError, /inside the repo/)
    end
  end

  describe Bench::Scorer do
    let(:config) { Thingie::Configuration.new(root: Dir.mktmpdir) }
    let(:reply) { { 'label' => 2 } }
    let(:client) do
      instance_double(Thingie::LlmClient, complete_with_schema: instance_double(RubyLLM::Message, content: reply))
    end

    before { allow(Thingie::LlmClient).to receive(:new).and_return(client) }

    it 'maps the one-based number in the reply to the label' do
      expect(described_class.new(config, labels).match([finding(nil)])).to eq([real_b])
    end

    it 'treats null, zero and out-of-range numbers as no match', :aggregate_failures do
      [nil, 0, 5].each do |value|
        allow(client).to receive(:complete_with_schema)
          .and_return(instance_double(RubyLLM::Message, content: { 'label' => value }))
        expect(described_class.new(config, labels).match([finding(nil)])).to eq([nil])
      end
    end

    it 'reads a reply that came back as a JSON string' do
      allow(client).to receive(:complete_with_schema)
        .and_return(instance_double(RubyLLM::Message, content: '{"label": 1}'))
      expect(described_class.new(config, labels).match([finding(nil)])).to eq([real_a])
    end

    it 'does not call the model for nothing' do
      expect(described_class.new(config, labels).match([])).to eq([])
      expect(client).not_to have_received(:complete_with_schema)
    end
  end

  describe Bench::Metrics do
    describe '.compute' do
      subject(:metrics) do
        described_class.compute(
          labels: labels,
          posted: [finding(real_a, severity: 2), finding(real_a, severity: 3), finding(nit, severity: 3),
                   finding(wrong, severity: 2, confidence: 3), finding(nil, severity: 4, unchecked: true)],
          held_back: [finding(real_b)],
          usage: usage, seconds: 90.4, changed_lines: 250,
          warnings: ['Could not verify x: Async::TimeoutError: execution expired', 'other']
        )
      end

      it 'counts the planted bugs found, once each, and the ones folded into the summary', :aggregate_failures do
        expect(metrics.dig('quality', 'real_recall')).to eq('found' => 1, 'total' => 2)
        expect(metrics.dig('quality', 'reals_held_back')).to eq(1)
        expect(metrics.dig('quality', 'first_push_recall')).to be_nil
      end

      it 'reads the noise off the posted threads' do
        expect(metrics['noise']).to include('posted' => 5, 'nit' => 1, 'wrong' => 1, 'unlabelled' => 1,
                                            'nit_rate' => 20, 'wrong_rate' => 20, 'threads_per_100_lines' => 2.0,
                                            'duplicates' => 1)
      end

      it 'checks the grades against the labels', :aggregate_failures do
        expect(metrics.dig('calibration', 'highs_real')).to eq('real' => 1, 'total' => 2)
        expect(metrics.dig('calibration', 'mediums_nit')).to eq('nit' => 1, 'total' => 2)
        expect(metrics.dig('calibration', 'conf3_posted')).to eq(1)
      end

      it 'records time, timeouts and cost', :aggregate_failures do
        expect(metrics['latency']).to eq('seconds' => 90, 'unchecked' => 1, 'critic_timeouts' => 1)
        expect(metrics['cost']).to eq('cost_usd' => 1.23, 'input_tokens' => 1000, 'output_tokens' => 50)
      end

      it 'leaves rates empty when nothing was posted', :aggregate_failures do
        empty = described_class.compute(labels: labels, posted: [], held_back: [], usage: {}, seconds: 0,
                                        changed_lines: 0, warnings: [])
        expect(empty['noise']).to include('nit_rate' => nil, 'wrong_rate' => nil, 'threads_per_100_lines' => nil)
        expect(empty.dig('cost', 'cost_usd')).to be_nil
      end
    end

    describe '.total' do
      let(:one) do
        described_class.compute(labels: labels, posted: [finding(real_a), finding(nit)], held_back: [],
                                usage: usage, seconds: 60, changed_lines: 100, warnings: [])
      end
      let(:two) do
        described_class.compute(labels: labels, posted: [finding(wrong, severity: 2)], held_back: [],
                                usage: usage, seconds: 30, changed_lines: 50, warnings: [])
      end

      it 'adds the counts and recomputes the rates over the sum', :aggregate_failures do
        total = described_class.total([one, two])
        expect(total.dig('quality', 'real_recall')).to eq('found' => 1, 'total' => 4)
        expect(total['noise']).to include('posted' => 3, 'nit' => 1, 'wrong' => 1, 'nit_rate' => 33,
                                          'wrong_rate' => 33, 'threads_per_100_lines' => 2.0)
        expect(total['latency']).to include('seconds' => 90)
        expect(total.dig('cost', 'cost_usd')).to eq(2.46)
        expect(total.dig('quality', 'first_push_recall')).to be_falsey
      end

      it 'keeps a cost nobody measured as unknown, not zero' do
        unpriced = described_class.compute(labels: labels, posted: [], held_back: [], usage: {}, seconds: 1,
                                           changed_lines: 1, warnings: [])
        expect(described_class.total([unpriced, unpriced]).dig('cost', 'cost_usd')).to be_nil
      end

      it 'is nil for nothing' do
        expect(described_class.total([])).to be_nil
      end
    end

    describe '.mean' do
      it 'averages the repeats leaf by leaf, keeping whole numbers whole', :aggregate_failures do
        a = { 'quality' => { 'real_recall' => { 'found' => 10, 'total' => 20 } }, 'noise' => { 'nit_rate' => 30 },
              'cost' => { 'cost_usd' => 2.0 } }
        b = { 'quality' => { 'real_recall' => { 'found' => 13, 'total' => 20 } }, 'noise' => { 'nit_rate' => 40 },
              'cost' => { 'cost_usd' => nil } }
        mean = described_class.mean([a, b])
        expect(mean.dig('quality', 'real_recall')).to eq('found' => 11.5, 'total' => 20)
        expect(mean.dig('noise', 'nit_rate')).to eq(35)
        expect(mean.dig('cost', 'cost_usd')).to eq(2.0)
      end

      it 'is the one total when there is only one' do
        expect(described_class.mean([{ 'a' => 1 }])).to eq('a' => 1)
      end
    end
  end

  describe Bench::RunFile do
    def review(kase, ref, repeat, found)
      metrics = Bench::Metrics.compute(labels: [real_a, real_b], posted: Array.new(found) { finding(real_a) },
                                       held_back: [], usage: usage, seconds: 10, changed_lines: 10, warnings: [])
      { 'case' => kase, 'ref' => ref, 'repeat' => repeat, 'metrics' => metrics }
    end

    it 'puts each first-push recall on its final-push row and averages the repeats', :aggregate_failures do
      reviews = [review('a', 'final-push', 0, 1), review('a', 'first-push', 0, 0), review('b', 'final-push', 0, 0),
                 review('a', 'final-push', 1, 1), review('a', 'first-push', 1, 1), review('b', 'final-push', 1, 1)]
      run = described_class.assemble(reviews, label: 'x')
      expect(run['cases'][0].dig('metrics', 'quality', 'first_push_recall')).to eq('found' => 0, 'total' => 2)
      expect(run['cases'][3].dig('metrics', 'quality', 'first_push_recall')).to eq('found' => 1, 'total' => 2)
      expect(run['cases'][2].dig('metrics', 'quality', 'first_push_recall')).to be_nil
      expect(run['totals'].dig('quality', 'real_recall')).to eq('found' => 1.5, 'total' => 4)
      expect(run['totals'].dig('latency', 'seconds')).to eq(20)
      expect(run['spread'].size).to eq(2)
    end

    it 'has no spread for a single run' do
      run = described_class.assemble([review('a', 'final-push', 0, 1)], label: 'x')
      expect(run['spread']).to be_nil
      expect(run['totals'].dig('latency', 'seconds')).to eq(10)
    end

    it 'merges one-case run files into one run, keeping the first file\'s provenance', :aggregate_failures do
      one = described_class.assemble([review('a', 'final-push', 0, 1)], label: 'a').merge('sha' => 'abc',
                                                                                          'model' => 'm')
      two = described_class.assemble([review('b', 'final-push', 0, 0)], label: 'b').merge('sha' => 'abc',
                                                                                          'model' => 'm')
      merged = described_class.merge([one, two], label: 'all')
      expect(merged['label']).to eq('all')
      expect(merged['cases'].map { |c| c['case'] }).to eq(%w[a b])
      expect(merged['totals'].dig('quality', 'real_recall')).to eq('found' => 1, 'total' => 4)
      expect(merged['totals'].dig('latency', 'seconds')).to eq(20)
      expect(merged.slice('sha', 'model')).to eq('sha' => 'abc', 'model' => 'm')
    end
  end

  describe Bench::Report do
    let(:totals) do
      {
        'quality' => { 'real_recall' => { 'found' => 4, 'total' => 5 }, 'first_push_recall' => nil,
                       'reals_held_back' => 0 },
        'noise' => { 'posted' => 10, 'nit' => 3, 'wrong' => 1, 'unlabelled' => 0, 'nit_rate' => 30,
                     'wrong_rate' => 10, 'threads_per_100_lines' => 1.5, 'duplicates' => 0 },
        'calibration' => { 'highs_real' => { 'real' => 2, 'total' => 2 },
                           'mediums_nit' => { 'nit' => 3, 'total' => 8 }, 'conf3_posted' => 0 },
        'latency' => { 'seconds' => 300, 'unchecked' => 0, 'critic_timeouts' => 0 },
        'cost' => { 'cost_usd' => 2.5, 'input_tokens' => 1, 'output_tokens' => 1 }
      }
    end
    let(:run) do
      { 'label' => 'abc-baseline', 'totals' => totals,
        'cases' => [{ 'case' => 'drafts', 'ref' => 'final-push', 'metrics' => totals }] }
    end
    let(:baseline) do
      worse = Marshal.load(Marshal.dump(totals))
      worse['noise']['nit_rate'] = 50
      worse['quality']['real_recall'] = { 'found' => 5, 'total' => 5 }
      other = Marshal.load(Marshal.dump(worse))
      other['noise']['nit_rate'] = 40
      { 'label' => 'main', 'totals' => worse, 'spread' => [worse, other] }
    end

    it 'renders the headline with the change against the baseline', :aggregate_failures do
      md = described_class.render(run, baseline: baseline)
      expect(md).to start_with("## Eval results\n\n`abc-baseline` against `main`")
      expect(md).to include('| Headline | main | abc-baseline | Change |')
      expect(md).to include('| Real recall | 5/5 | 4/5 | -0.2 worse |')
      expect(md).to include('| Nit rate | 50% (40..50) | 30% | -20 better |')
      expect(md).to include('| Minutes | 5.0 | 5.0 | same |')
    end

    it 'keeps the columns in place when the baseline has no value', :aggregate_failures do
      baseline['totals']['noise']['nit_rate'] = nil
      baseline['totals']['cost']['cost_usd'] = nil
      baseline.delete('spread')
      md = described_class.render(run, baseline: baseline)
      expect(md).to include('| Nit rate | - | 30% | - |')
      expect(md).to include('| Dollars | - | 2.5 | - |')
    end

    it 'names the models and version under the title' do
      md = described_class.render(run.merge('model' => 'm', 'critic_model' => 'c', 'thingie' => '0.1'))
      expect(md).to include("\n\n`abc-baseline` on m (critic c), Thingie 0.1\n")
    end

    it 'renders every dimension and the cases', :aggregate_failures do
      md = described_class.render(run)
      expect(md).to include('### Quality', '### Noise', '### Calibration', '### Latency', '### Cost', '### Cases')
      expect(md).to include('| Highs that are real | 2/2 |')
      expect(md).to include('| Caught at the first push | - |')
      expect(md).to include('| drafts | final-push | 4/5 | 3 | 1 | 10 | 300 | 2.5 |')
    end

    it 'says so when a run has no head reviews' do
      empty = { 'label' => 'x', 'totals' => nil, 'cases' => [] }
      expect(described_class.render(empty)).to end_with('No final-push reviews in this run.')
    end
  end
end
