# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::SystemOneClassifier do
  let(:settings) do
    { 'system_one_enabled' => true, 'system_one_api_key' => 'sk-test', 'system_one_model' => 'jev-latest',
      'system_one_api_base' => 'https://example.test/api/', 'request_timeout' => 7 }
  end
  let(:classifier) { described_class.new(settings) }
  let(:http) do
    instance_double(Net::HTTP, :use_ssl= => true, :open_timeout= => 7, :read_timeout= => 7, :write_timeout= => 7)
  end
  let(:questions) { { sqli: { type: 'noul', instructions: 'Is there SQL injection?' } } }

  before { allow(Net::HTTP).to receive(:new).and_return(http) }

  def stub_response(klass, body)
    response = klass.new('1.1', '200', 'msg')
    allow(response).to receive(:body).and_return(body.to_json)
    allow(http).to receive(:post).and_return(response)
  end

  it 'returns the probability of yes for a noul and the position for a score', :aggregate_failures do
    stub_response(Net::HTTPOK, answers: { 'sqli' => { 'type' => 'noul', 'noul' => 0.97 },
                                          'overall' => { 'type' => 'score', 'score' => 1.9, 'confidence' => 0.8 } })

    result = classifier.classify(state: { path: 'a.rb' },
                                 questions: questions.merge(overall: { type: 'score', instructions: 'Risk?',
                                                                       criteria: %w[low mid high] }))

    expect(result).to eq(sqli: 0.97, overall: 0.95)
  end

  it 'divides an integer score as a float' do
    stub_response(Net::HTTPOK, answers: { 'overall' => { 'type' => 'score', 'score' => 1 } })

    result = classifier.classify(state: { path: 'a.rb' },
                                 questions: { overall: { type: 'score', instructions: 'Risk?',
                                                         criteria: %w[low mid high] } })

    expect(result).to eq(overall: 0.5)
  end

  it 'sends the model, state and questions to the System One endpoint', :aggregate_failures do
    stub_response(Net::HTTPOK, answers: { 'sqli' => { 'type' => 'noul', 'noul' => 0.1 } })

    classifier.classify(state: { path: 'a.rb' }, questions: questions)

    expect(http).to have_received(:post) do |post_path, body, headers|
      payload = JSON.parse(body)
      expect(post_path).to eq('/api/v1/systemone')
      expect(payload).to include('model' => 'jev-latest', 'state' => { 'path' => 'a.rb' })
      expect(payload['questions']).to eq('sqli' => { 'type' => 'noul', 'instructions' => 'Is there SQL injection?' })
      expect(headers['Authorization']).to eq('Bearer sk-test')
    end
  end

  it 'applies the configured request timeout', :aggregate_failures do
    stub_response(Net::HTTPOK, answers: { 'sqli' => { 'type' => 'noul', 'noul' => 0.1 } })

    classifier.classify(state: {}, questions: questions)

    expect(http).to have_received(:open_timeout=).with(7)
    expect(http).to have_received(:read_timeout=).with(7)
  end

  it 'raises SystemOneError when the request times out' do
    allow(http).to receive(:post).and_raise(Net::ReadTimeout)

    expect { classifier.classify(state: {}, questions: questions) }
      .to raise_error(Thingie::SystemOneError, /ReadTimeout/)
  end

  it 'raises SystemOneError when the API rejects the request' do
    stub_response(Net::HTTPUnauthorized, error: 'nope')

    expect { classifier.classify(state: {}, questions: questions) }
      .to raise_error(Thingie::SystemOneError, /failed/)
  end

  it 'raises SystemOneError when an answer is missing from the response' do
    stub_response(Net::HTTPOK, answers: {})

    expect { classifier.classify(state: {}, questions: questions) }
      .to raise_error(Thingie::SystemOneError, /Unexpected/)
  end

  [Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse].each do |error|
    it "raises SystemOneError when the connection fails with #{error}" do
      allow(http).to receive(:post).and_raise(error)

      expect { classifier.classify(state: {}, questions: questions) }
        .to raise_error(Thingie::SystemOneError, /#{error}/)
    end
  end

  [
    ['an answer that is not an object', { 'sqli' => 'yes' }],
    ['a null noul', { 'sqli' => { 'type' => 'noul', 'noul' => nil } }],
    ['a non-numeric noul', { 'sqli' => { 'type' => 'noul', 'noul' => 'high' } }],
    ['answers that are not an object', ['sqli']]
  ].each do |description, answers|
    it "raises SystemOneError for #{description}" do
      stub_response(Net::HTTPOK, answers: answers)

      expect { classifier.classify(state: {}, questions: questions) }
        .to raise_error(Thingie::SystemOneError, /Unexpected/)
    end
  end

  it 'raises SystemOneError for a null score instead of reporting zero risk' do
    stub_response(Net::HTTPOK, answers: { 'overall' => { 'type' => 'score', 'score' => nil } })

    expect do
      classifier.classify(state: {}, questions: { overall: { type: 'score', criteria: %w[low high] } })
    end.to raise_error(Thingie::SystemOneError, /Unexpected/)
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
