# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::ToolBudget do
  # Only `dup` and `call` matter to the budget, so a plain object stands in for a ruby_llm tool.
  let(:tool_class) do
    Class.new do
      attr_reader :runs

      def initialize
        @runs = 0
      end

      def call(*args, **options)
        @runs += 1
        "ran with #{args.inspect} #{options.inspect}"
      end
    end
  end
  let(:tool) { tool_class.new }

  it 'lets the first calls run and refuses the rest with a note to answer now', :aggregate_failures do
    budget = described_class.new(2)
    copy = budget.wrap([tool]).first

    results = Array.new(3) { copy.call({ path: 'a.rb' }) }

    expect(results.first(2)).to all(include('ran with'))
    expect(results.last).to eq(described_class::SPENT)
    expect(budget.used).to eq(2)
    expect(budget.refused).to eq(1)
  end

  it 'passes the arguments through in either ruby_llm style', :aggregate_failures do
    copy = described_class.new(5).wrap([tool]).first

    expect(copy.call({ path: 'a.rb' })).to eq('ran with [{path: "a.rb"}] {}')
    expect(copy.call(path: 'a.rb', tool_call: :tc)).to eq('ran with [] {path: "a.rb", tool_call: :tc}')
  end

  it 'leaves the original tool alone, so the next call starts fresh', :aggregate_failures do
    budget = described_class.new(1)
    copy = budget.wrap([tool]).first
    copy.call({})
    copy.call({})

    expect(tool.call({})).to include('ran with')
    expect(described_class.new(1).wrap([tool]).first.call({})).to include('ran with')
  end

  it 'is no cap at all for 0 or nil', :aggregate_failures do
    [0, nil].each do |limit|
      budget = described_class.new(limit)
      expect(budget).not_to be_active
      expect(budget.wrap([tool])).to eq([tool])
    end
  end
end
