# frozen_string_literal: true

require 'spec_helper'
require_relative '../../evals/bench/lib/risk'

RSpec.describe 'Bench::Risk' do
  def scored(security, overall, rating, expected = nil)
    { 'scores' => { 'security' => security, 'overall' => overall }, 'rating' => rating, 'expected' => expected }
  end

  def entry(files, repeat: 0, kase: 'escrow', error: nil)
    { 'case' => kase, 'ref' => 'final-push', 'model' => 'm', 'repeat' => repeat, 'seconds' => 1.0,
      'rating' => error ? nil : 'risky', 'max' => error ? {} : { 'overall' => 0.6 }, 'files' => files,
      'error' => error }
  end

  let(:root) { Dir.mktmpdir }
  let(:case_dir) { File.join(root, 'cases', 'escrow') }
  let(:kase) { Bench::Case.load('escrow') }
  let(:risk_file) { File.join(case_dir, 'risk.yml') }

  before do
    stub_const('Bench::ROOT', root)
    stub_const('Bench::APP', File.join(root, 'app'))
    FileUtils.mkdir_p(File.join(root, 'app'))
    File.write(File.join(root, 'app', 'keep.rb'), "class Keep\nend\n")
    FileUtils.mkdir_p(File.join(case_dir, 'final-push'))
    File.write(File.join(case_dir, 'final-push', 'keep.rb'), "class Keep\n  def call = true\nend\n")
    File.write(File.join(case_dir, 'final-push', 'new.rb'), "class New\nend\n")
    File.write(File.join(case_dir, 'case.yml'), "title: Escrow\nlabels: []\n")
    File.write(File.join(root, 'config.toml'), "model = \"m\"\n")
  end

  after { FileUtils.rm_rf(root) }

  describe Bench::Risk::Expectations do
    it 'loads nothing when the case has no risk.yml' do
      expect(described_class.load(kase)).to eq({})
    end

    {
      'an unknown question' => [{ 'speed' => true }, /unknown question "speed"/],
      'a probability that is not true or false' => [{ 'security' => 0.4 }, /security is 0.4, not true or false/],
      'an overall outside the levels' => [{ 'overall' => 'scary' }, /overall is "scary", not trivial or routine/]
    }.each do |what, (answers, message)|
      it "rejects #{what}" do
        File.write(risk_file, YAML.dump('final-push' => { 'keep.rb' => answers }))
        expect { described_class.load(kase) }.to raise_error(ArgumentError, message)
      end
    end

    it 'rejects first-push answers on a case without a first-push overlay' do
      File.write(risk_file, YAML.dump('first-push' => { 'keep.rb' => { 'security' => true } }))
      expect { described_class.load(kase) }.to raise_error(ArgumentError, /escrow: .*no first-push/)
    end

    it 'rejects a risk.yml that is not a map of pushes' do
      File.write(risk_file, "false\n")
      expect { described_class.load(kase) }.to raise_error(ArgumentError, /must map pushes to files/)
    end

    it 'adds a guess for each missing file, keeps existing ones as written, and round-trips', :aggregate_failures do
      described_class.write(kase, 'final-push' => { 'keep.rb' => { 'security' => true } })
      run_entry = entry({ 'keep.rb' => scored(0.1, 0.9, 'critical'), 'new.rb' => scored(0.5, 0.2, 'routine') })

      expect(described_class.bootstrap(kase, [run_entry])).to eq(1)
      expect(described_class.load(kase)).to eq(
        'final-push' => { 'keep.rb' => { 'security' => true },
                          'new.rb' => { 'security' => true, 'overall' => 'routine' } }
      )
      expect(File.read(risk_file)).to start_with(described_class::HEADER)
      expect { described_class.bootstrap(kase, [run_entry]) }.not_to(change { File.read(risk_file) })
    end
  end

  describe Bench::Risk::Scoring do
    let(:classifier) { instance_double(Thingie::SystemOneClassifier) }
    let(:repo) { kase.build(File.join(root, 'config.toml')) }
    let(:expectations) { { 'final-push' => { 'keep.rb' => { 'security' => false, 'overall' => 'routine' } } } }

    def score
      described_class.score(kase: kase, repo: repo, ref: 'final-push', overrides: {}, model: 'jev',
                            expectations: expectations, classifier: classifier)
    end

    it 'scores each file and attaches its expectation, nil for a file without one', :aggregate_failures do
      allow(classifier).to receive(:classify) do |state:, **|
        { security: state[:path] == 'keep.rb' ? 0.2 : 0.7, overall: 0.3 }
      end

      result = score

      expect(result.slice('case', 'ref', 'model', 'rating', 'error'))
        .to eq('case' => 'escrow', 'ref' => 'final-push', 'model' => 'jev', 'rating' => 'routine', 'error' => nil)
      expect(result['max']).to eq('security' => 0.7, 'overall' => 0.3)
      expect(result['files']['keep.rb']).to eq('scores' => { 'security' => 0.2, 'overall' => 0.3 },
                                               'rating' => 'routine',
                                               'expected' => { 'security' => false, 'overall' => 'routine' })
      expect(result['files']['new.rb']['expected']).to be_nil
    end

    it 'records a System One failure as an errored entry with no files', :aggregate_failures do
      allow(classifier).to receive(:classify).and_raise(Thingie::SystemOneError, 'rate limited')
      # Stubbed, not captured: async's console logger would keep a swapped-in $stderr StringIO and crash later specs.
      allow(described_class).to receive(:warn)

      result = score

      expect(described_class).to have_received(:warn).with(/rate limited/)
      expect(result['error']).to eq('Thingie::SystemOneError: rate limited')
      expect(result.slice('rating', 'max', 'files')).to eq('rating' => nil, 'max' => {}, 'files' => {})
    end
  end

  describe Bench::Risk::Summary do
    def summary(*entries) = described_class.compute(entries).fetch('m')

    it 'ranks, calibrates and counts the probability answers against their expectations', :aggregate_failures do
      security = summary(entry({ 'a' => scored(0.9, 0.5, 'risky', { 'security' => true }),
                                 'b' => scored(0.2, 0.1, 'trivial', { 'security' => false }) }))
                 .dig('questions', 'security')

      expect(security.slice('mean', 'yes_mean', 'no_mean', 'auc', 'brier'))
        .to eq('mean' => 0.55, 'yes_mean' => 0.9, 'no_mean' => 0.2, 'auc' => 1.0, 'brier' => 0.025)
      expect(security['hits']).to eq('found' => 2, 'total' => 2)
    end

    it 'counts a tie as half a win, and has no AUC without an expected no', :aggregate_failures do
      tie = summary(entry({ 'a' => scored(0.5, 0.5, 'risky', { 'security' => true }),
                            'b' => scored(0.5, 0.1, 'trivial', { 'security' => false }) }))
      only_yes = summary(entry({ 'a' => scored(0.5, 0.5, 'risky', { 'security' => true }) }))

      expect(tie.dig('questions', 'security', 'auc')).to eq(0.5)
      expect(only_yes.dig('questions', 'security', 'auc')).to be_nil
    end

    it 'scores the rating against the expected one', :aggregate_failures do
      overall = summary(entry({ 'a' => scored(0.1, 0.9, 'critical', { 'overall' => 'risky' }),
                                'b' => scored(0.1, 0.1, 'trivial', { 'overall' => 'trivial' }),
                                'c' => scored(0.1, 0.4, 'routine') })).dig('questions', 'overall')

      expect(overall['hits']).to eq('found' => 1, 'total' => 2)
      expect(overall.dig('confusion', 'risky')).to eq('trivial' => 0, 'routine' => 0, 'risky' => 0, 'critical' => 1)
      expect(overall.dig('by_expected', 'risky')).to eq('mean' => 0.9, 'n' => 1)
      expect(overall.dig('by_expected', 'routine')).to eq('mean' => nil, 'n' => 0)
    end

    it 'counts each file once at its first answer, and reports its mean range across repeats', :aggregate_failures do
      quiet = { 'security' => false }
      first = entry({ 'a' => scored(0.2, 0.1, 'trivial', quiet), 'b' => scored(0.5, 0.1, 'trivial') })
      second = entry({ 'a' => scored(0.6, 0.1, 'trivial', quiet), 'b' => scored(0.5, 0.1, 'trivial') }, repeat: 1)

      expect(summary(first).dig('questions', 'security', 'spread')).to be_nil
      both = summary(first, second)
      expect(both.dig('questions', 'security', 'spread')).to eq(0.2)
      expect(both['files']).to eq(2)
      expect(both.dig('questions', 'security', 'hits')).to eq('found' => 1, 'total' => 1)
    end
  end

  describe Bench::Risk::Report do
    def render(*entries)
      run = Bench::Risk::RunFile.assemble(entries, label: 'l', models: ['m'], variant: 'baseline',
                                                   floors: { 'trivial' => 0.0, 'routine' => 0.17 })
      described_class.render(run)
    end

    it 'renders the headline, the questions without a spread, failed entries and file answers',
       :aggregate_failures do
      report = render(entry({ 'a.rb' => scored(0.9, 0.6, 'risky', { 'security' => true, 'overall' => 'risky' }) }),
                      entry({}, kase: 'broken', error: 'Thingie::SystemOneError: down'))

      expect(report).to start_with("## Risk eval results\n")
      expect(report).to include('| m | 1 | 1 | 1 | 1/1 | 0.01 | 2.0 |')
      expect(report).to include('| Question | Mean | Expected yes | Expected no | AUC | Brier | Hits |')
      expect(report).not_to include('Spread')
      expect(report).to include('| broken | final-push | m | Error: Thingie::SystemOneError: down |')
      expect(report).to include('| a.rb | risky | risky | 0.90 yes |')
    end

    it 'escapes pipes and newlines so a value cannot break its table' do
      report = render(entry({}, kase: 'broken', error: "Thingie::SystemOneError: a | b\nc"))

      expect(report).to include('| Error: Thingie::SystemOneError: a \| b c |')
    end
  end
end
