# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::CallTimeline do
  subject(:timeline) { described_class.new }

  # Each event reads the clock once, in order: the start, then one reading per tool event and one for the summary.
  def stub_clock(*times)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(*times)
  end

  it 'splits the total into tool time and model and network time', :aggregate_failures do
    stub_clock(0.0, 10.0, 14.0, 20.0, 21.0, 50.0)
    timeline.tool_started('search a')
    timeline.tool_finished
    timeline.tool_started('file b')
    timeline.tool_finished

    summary = timeline.summary

    expect(summary).to include('total 50.0s', 'tools 2 calls 5.0s', 'model and network 45.0s')
    expect(summary).to include('slowest tools: search a 4.0s, file b 1.0s')
  end

  it 'counts overlapping tool calls once', :aggregate_failures do
    stub_clock(0.0, 1.0, 2.0, 6.0, 8.0, 10.0)
    timeline
    timeline.tool_started('a')
    timeline.tool_started('b')
    timeline.tool_finished
    timeline.tool_finished

    expect(timeline.summary).to include('tools 2 calls 7.0s')
  end

  it 'says when a tool call never came back, as for a call cut off by a time limit', :aggregate_failures do
    stub_clock(0.0, 5.0, 100.0)
    timeline
    timeline.tool_started('search stuck')

    expect(timeline.summary).to include('unfinished tool calls 1', 'tools 0 calls 95.0s')
  end

  it 'reports no tools for a call that used none' do
    stub_clock(0.0, 12.0)
    timeline

    expect(timeline.summary).to eq('total 12.0s | tools 0 calls 0.0s | model and network 12.0s')
  end
end
