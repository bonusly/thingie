# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::GitHub::LinkedRuns do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:linked_runs) { described_class.new(clients: [client], repos: ['bonusly/loop-de-loop']) }

  let(:client) { instance_double(Octokit::Client) }
  let(:url) { 'https://github.com/bonusly/loop-de-loop/actions/runs' }

  before do
    allow(client).to receive_messages(repository: double('repo', default_branch: 'main')) # rubocop:disable RSpec/VerifiedDoubles
  end

  def stub_run(id, status:, branch: 'test-branch', on: client)
    allow(on).to receive(:workflow_run).with('bonusly/loop-de-loop', id)
                                       .and_return(double('run', head_sha: "sha#{id}", head_branch: branch)) # rubocop:disable RSpec/VerifiedDoubles
    allow(on).to receive(:compare).with('bonusly/loop-de-loop', 'main', "sha#{id}")
                                  .and_return(double('comparison', status: status)) # rubocop:disable RSpec/VerifiedDoubles
  end

  it 'reports each linked run off the default branch once', :aggregate_failures do
    stub_run(1, status: 'ahead')
    stub_run(2, status: 'identical')
    result = linked_runs.check(["#{url}/1 and #{url}/1/job/9", nil, 'http://www.GitHub.com/bonusly/loop-de-loop/actions/runs/2'])

    expect(result.off_branch).to eq(['bonusly/loop-de-loop run 1 ran from `test-branch`, not main'])
    expect(result.unchecked).to be_empty
    expect(client).to have_received(:repository).once
  end

  it 'ignores links to other repositories' do
    result = linked_runs.check(['https://github.com/bonusly/loop-de-loop-fork/actions/runs/3'])

    expect(result.to_a).to eq([[], []])
  end

  it 'names the commit when the run has no branch' do
    stub_run(4, status: 'diverged', branch: nil)

    expect(linked_runs.check(["#{url}/4"]).off_branch).to eq(['bonusly/loop-de-loop run 4 ran from `sha4`, not main'])
  end

  it 'falls back to the next client when the first cannot read the run' do
    pat = instance_double(Octokit::Client, repository: double('repo', default_branch: 'main')) # rubocop:disable RSpec/VerifiedDoubles
    allow(client).to receive(:workflow_run).and_raise(Octokit::NotFound)
    stub_run(5, status: 'ahead', on: pat)
    result = described_class.new(clients: [client, pat], repos: ['bonusly/loop-de-loop']).check(["#{url}/5"])

    expect(result.off_branch.size).to eq(1)
  end

  it 'lists a run no client can read as unchecked', :aggregate_failures do
    allow(client).to receive(:workflow_run).and_raise(Faraday::TimeoutError)
    result = linked_runs.check(["#{url}/6"])

    expect(result.off_branch).to be_empty
    expect(result.unchecked).to eq(['bonusly/loop-de-loop run 6'])
  end
end
