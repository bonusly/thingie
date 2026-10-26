# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::ToolBudget do
  # Only `dup` and `call` matter to the budget, so a plain object stands in for a ruby_llm tool.
  let(:tool_class) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def call(*args, **options)
        @calls << [args, options]
        'ran'
      end
    end
  end
  let(:tool) { tool_class.new }

  it 'lets the first calls run and refuses the rest with a note to answer now', :aggregate_failures do
    budget = described_class.new(2)
    copy = budget.wrap([tool]).first

    results = Array.new(3) { copy.call({ path: 'a.rb' }) }

    expect(results.first(2)).to all(eq('ran'))
    expect(results.last).to eq(described_class::SPENT)
    expect(budget.used).to eq(2)
    expect(budget.refused).to eq(1)
  end

  it 'does not charge a call that comes back as a failure', :aggregate_failures do
    failing = Class.new { def call(*, **) = Thingie::ToolBudget::Failure.new('Path `a.rb` does not exist.') }.new
    budget = described_class.new(1)
    miss, hit = budget.wrap([failing, tool])

    expect(miss.call({})).to eq('Path `a.rb` does not exist.')
    expect(hit.call({})).to eq('ran')
    expect(budget.used).to eq(1)
    expect(budget.failed).to eq(1)
  end

  it 'does not charge a call that raises' do
    raising = Class.new { def call(*, **) = raise(IOError, 'gone') }.new
    budget = described_class.new(1)
    copy = budget.wrap([raising]).first

    expect { copy.call({}) }.to raise_error(IOError)
    expect(budget.used).to eq(0)
  end

  it 'charges failures once as many as the budget have been free', :aggregate_failures do
    failing = Class.new { def call(*, **) = Thingie::ToolBudget::Failure.new('no') }.new
    budget = described_class.new(2)
    copy = budget.wrap([failing]).first

    results = Array.new(5) { copy.call({}) }

    expect(results.first(4)).to all(eq('no'))
    expect(results.last).to eq(described_class::SPENT)
    expect(budget.failed).to eq(2)
  end

  it 'passes the arguments through in either ruby_llm style', :aggregate_failures do
    copy = described_class.new(5).wrap([tool]).first

    copy.call({ path: 'a.rb' })
    copy.call(path: 'a.rb', tool_call: :tc)

    expect(tool.calls).to eq([[[{ path: 'a.rb' }], {}], [[], { path: 'a.rb', tool_call: :tc }]])
  end

  it 'leaves the original tool alone, so the next call starts fresh', :aggregate_failures do
    budget = described_class.new(1)
    copy = budget.wrap([tool]).first
    copy.call({})
    copy.call({})

    expect(tool.call({})).to eq('ran')
    expect(described_class.new(1).wrap([tool]).first.call({})).to eq('ran')
  end

  it 'is no cap at all for 0 or nil', :aggregate_failures do
    [0, nil].each do |limit|
      budget = described_class.new(limit)
      expect(budget).not_to be_active
      expect(budget.wrap([tool])).to eq([tool])
    end
  end
end
