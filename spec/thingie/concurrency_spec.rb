# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::Concurrency do
  describe '.with_timeout' do
    def in_reactor(&)
      described_class.map([1], 1, &)
    end

    it 'returns the block value when it finishes in time' do
      expect(in_reactor { described_class.with_timeout(1) { :done } }).to eq([:done])
    end

    it 'raises when the block runs past the limit' do
      expect { in_reactor { described_class.with_timeout(0.05) { sleep(5) } } }.to raise_error(Async::TimeoutError)
    end

    it 'applies no limit for nil or zero', :aggregate_failures do
      expect(described_class.with_timeout(nil) { :a }).to eq(:a)
      expect(described_class.with_timeout(0) { :b }).to eq(:b)
    end
  end
end
