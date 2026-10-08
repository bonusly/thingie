# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::GitHub::DiffLines do # rubocop:disable RSpec/SpecFilePathFormat
  # New-side lines: 10 context, 11 added, 12 context; then a second hunk starting at 20 with an
  # added line, a deleted line, a context line and a "no newline" marker.
  let(:patch) do
    [
      '@@ -10,3 +10,4 @@', ' ctx10', '+added11', ' ctx12',
      '@@ -30,2 +20,2 @@', '+added20', '-gone', ' ctx21', '\ No newline at end of file'
    ].join("\n")
  end

  it 'returns added and context lines by default, in every hunk' do
    expect(described_class.new_side(patch)).to eq(Set[10, 11, 12, 20, 21])
  end

  it 'returns only the added lines on request' do
    expect(described_class.new_side(patch, added_only: true)).to eq(Set[11, 20])
  end

  it 'returns nothing for an empty patch' do
    expect(described_class.new_side('')).to eq(Set.new)
  end
end
