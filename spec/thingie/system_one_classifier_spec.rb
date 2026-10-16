# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::SystemOneClassifier do
  let(:settings) do
    { 'system_one_enabled' => true, 'system_one_api_key' => 'sk-test', 'system_one_model' => 'jev-latest',
      'system_one_api_base' => 'https://example.test/api/', 'request_timeout' => 7 }
  end
  let(:classifier) { described_class.new(settings) }
  let(:questions) { { sqli: { type: :probability, instructions: 'Is there SQL injection?' } } }
  let(:three_levels) { { type: :score, instructions: 'Risk?', levels: %w[low mid high] } }

  # A judgment answering each name with a probability (Float) or a score ({ score: Float }).
  def judgment(**values)
    answers = values.transform_values do |value|
      if value.is_a?(Hash)
        instance_double(RubyLLM::Score, score: value[:score])
      else
        instance_double(RubyLLM::Probability, probability: value)
      end
    end
    instance_double(RubyLLM::Judgment).tap do |judgment|
      allow(judgment).to receive(:fetch) { |name| answers.fetch(name.to_sym) }
    end
  end

  def stub_judgment(**answers)
    allow(classifier.llm_context).to receive(:judge).and_return(judgment(**answers))
  end

  it 'returns the probability of yes and the scaled position of a score', :aggregate_failures do
    stub_judgment(sqli: 0.97, overall: { score: 1.9 })

    result = classifier.classify(state: { path: 'a.rb' }, questions: questions.merge(overall: three_levels))

    expect(result).to eq(sqli: 0.97, overall: 0.95)
  end

  it 'reads a single-level score as its position' do
    stub_judgment(overall: { score: 0 })

    result = classifier.classify(state: {}, questions: { overall: three_levels.merge(levels: %w[only]) })

    expect(result).to eq(overall: 0.0)
  end

  it 'asks the TypeSafe provider for the configured model' do
    stub_judgment(sqli: 0.1)

    classifier.classify(state: { 'path' => 'a.rb' }, questions: questions)

    expect(classifier.llm_context).to have_received(:judge)
      .with({ 'path' => 'a.rb' }, questions: questions, provider: :typesafe, model: 'jev-latest',
                                  assume_model_exists: true)
  end

  it 'configures its own context without touching the global one', :aggregate_failures do
    config = classifier.llm_context.config

    expect(config.typesafe_api_base).to eq('https://example.test/api')
    expect(config.typesafe_api_key).to eq('sk-test')
    expect(config.request_timeout).to eq(7)
    expect(RubyLLM.config.typesafe_api_key).not_to eq('sk-test')
  end

  it 'raises SystemOneError when the API rejects the request' do
    allow(classifier.llm_context).to receive(:judge).and_raise(RubyLLM::UnauthorizedError.new('nope'))

    expect { classifier.classify(state: {}, questions: questions) }
      .to raise_error(Thingie::SystemOneError, /failed.*nope/)
  end

  it 'raises SystemOneError when the connection fails' do
    allow(classifier.llm_context).to receive(:judge).and_raise(Faraday::ConnectionFailed.new('refused'))

    expect { classifier.classify(state: {}, questions: questions) }
      .to raise_error(Thingie::SystemOneError, /failed/)
  end

  it 'raises SystemOneError when an answer is missing' do
    stub_judgment

    expect { classifier.classify(state: {}, questions: questions) }
      .to raise_error(Thingie::SystemOneError, /Unexpected/)
  end

  [
    ['a probability above 1', 1.5, { type: :probability }],
    ['a negative probability', -0.1, { type: :probability }],
    ['a score above the last level', { score: 2.5 }, { type: :score, levels: %w[low mid high] }],
    ['an infinite score', { score: Float::INFINITY }, { type: :score, levels: %w[low mid high] }]
  ].each do |description, answer, question|
    it "raises SystemOneError for an out-of-range answer: #{description}" do
      stub_judgment(q: answer)

      expect { classifier.classify(state: {}, questions: { q: question }) }
        .to raise_error(Thingie::SystemOneError, /Unexpected/)
    end
  end

  it 'refuses to run unless enabled' do
    expect { described_class.new(settings.merge('system_one_enabled' => false)) }
      .to raise_error(Thingie::ConfigurationError, /disabled/)
  end

  {
    'system_one_api_key' => 'API_KEY',
    'system_one_model' => 'MODEL',
    'system_one_api_base' => 'API_BASE'
  }.each do |key, name|
    it "requires #{key}" do
      expect { described_class.new(settings.merge(key => ' ')) }
        .to raise_error(Thingie::ConfigurationError, /Missing SYSTEM_ONE_#{name}/)
    end
  end
end
