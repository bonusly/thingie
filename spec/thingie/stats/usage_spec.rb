# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Thingie::Stats::Usage do
  def response(input: nil, output: nil, cache_read: nil, cache_write: nil, cost_total: nil)
    cost = instance_double(RubyLLM::Cost, total: cost_total) if cost_total
    instance_double(RubyLLM::Message,
                    input_tokens: input, output_tokens: output,
                    cache_read_tokens: cache_read, cache_write_tokens: cache_write,
                    cost: cost)
  end

  it 'starts with all counters nil' do
    usage = described_class.new
    expect(usage.to_h).to eq('input_tokens' => nil, 'output_tokens' => nil,
                             'cache_read_tokens' => nil, 'cache_write_tokens' => nil,
                             'cost_usd' => nil)
  end

  it 'accumulates token fields across multiple responses' do
    usage = described_class.new
    usage.record(response(input: 100, output: 50, cost_total: 0.0001))
    usage.record(response(input: 200, output: 30, cache_read: 10, cost_total: 0.0002))

    expect(usage.input_tokens).to eq(300)
    expect(usage.output_tokens).to eq(80)
    expect(usage.cache_read_tokens).to eq(10)
    expect(usage.cache_write_tokens).to be_nil
    expect(usage.cost).to be_within(1e-9).of(0.0003)
  end

  it 'is a no-op on a nil response' do
    usage = described_class.new
    usage.record(nil)
    expect(usage.input_tokens).to be_nil
    expect(usage.cost).to be_nil
  end

  it 'keeps token data even when the cost accessor raises' do
    raising_cost = Object.new
    allow(raising_cost).to receive(:total).and_raise(StandardError, 'boom')
    bad_response = instance_double(RubyLLM::Message, input_tokens: 100, output_tokens: 50,
                                                     cache_read_tokens: nil, cache_write_tokens: nil,
                                                     cost: raising_cost)

    usage = described_class.new
    usage.record(bad_response)

    # Tokens were summed before the cost accessor was touched, so they survive.
    expect(usage.input_tokens).to eq(100)
    expect(usage.output_tokens).to eq(50)
  end

  it 'never raises when the response is malformed' do
    weird = Object.new
    usage = described_class.new

    expect { usage.record(weird) }.not_to raise_error
    expect(usage.input_tokens).to be_nil
  end
end
