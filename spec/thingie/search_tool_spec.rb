# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::SearchTool do
  include GitRepo

  subject(:tool) { described_class.new(root: repo) }

  let(:repo) { Dir.mktmpdir }

  before do
    git(repo, 'init', '-q', '-b', 'main')
    git_write(repo, 'app/award.rb', "class Award\n  def amounts_within_max\n    true\n  end\nend\n")
    git_write(repo, 'app/caller.rb', "Award.new.amounts_within_max\nAWARD.Amounts_Within_Max\n")
    git_write(repo, 'docs/readme.md', "amounts_within_max is documented here\n")
    git_commit(repo, 'base')
  end

  after { FileUtils.rm_rf(repo) }

  it 'returns matching lines as path:line:text', :aggregate_failures do
    result = tool.execute(pattern: 'amounts_within_max')

    expect(result).to include('app/award.rb:2:  def amounts_within_max')
    expect(result).to include('app/caller.rb:1:Award.new.amounts_within_max')
  end

  it 'limits the search to a path inside the repository', :aggregate_failures do
    result = tool.execute(pattern: 'amounts_within_max', path: 'app')

    expect(result).to include('app/award.rb')
    expect(result).not_to include('docs/readme.md')
  end

  it 'matches case-insensitively on request' do
    expect(tool.execute(pattern: 'amounts_within_max', path: 'app/caller.rb', ignore_case: true))
      .to include('app/caller.rb:2:AWARD.Amounts_Within_Max')
  end

  it 'says so when nothing matches' do
    expect(tool.execute(pattern: 'no_such_symbol')).to eq('No matches for `no_such_symbol`.')
  end

  it 'refuses a path that escapes the repository' do
    expect(tool.execute(pattern: 'x', path: '../outside')).to eq('Path `../outside` is outside the repository.')
  end

  it 'reports an invalid regular expression instead of raising' do
    expect(tool.execute(pattern: '(unclosed')).to start_with('Search for `(unclosed` failed:')
  end

  it 'treats a pattern that looks like an option as a pattern, not a flag' do
    expect(tool.execute(pattern: '--files-with-matches')).to eq('No matches for `--files-with-matches`.')
  end

  it 'rejects an empty or oversized pattern', :aggregate_failures do
    expect(tool.execute(pattern: '  ')).to eq('Pattern is empty.')
    expect(tool.execute(pattern: 'a' * 201)).to eq('Pattern is longer than 200 characters.')
  end

  it 'truncates a long result and says there is more', :aggregate_failures do
    git_write(repo, 'big.txt', Array.new(70) { |n| "needle #{n}" }.join("\n"))
    git_commit(repo, 'big')

    result = tool.execute(pattern: 'needle')

    expect(result.lines.size).to eq(61)
    expect(result).to end_with('... more matches not shown; narrow the pattern or path.')
  end

  it 'does not give a path pathspec magic, so it cannot widen the search', :aggregate_failures do
    result = tool.execute(pattern: 'amounts_within_max', path: ':(exclude)app')

    expect(result).not_to include('docs/readme.md')
    expect(result).to eq('No matches for `amounts_within_max`.')
  end

  it 'stops reading once it has enough lines instead of buffering the whole result' do
    git_write(repo, 'huge.txt', Array.new(20_000) { |n| "needle #{n}" }.join("\n"))
    git_commit(repo, 'huge')
    reads = 0
    allow(Open3).to receive(:popen3).and_wrap_original do |original, *argv, &block|
      original.call(*argv) do |stdin, stdout, stderr, waiter|
        allow(stdout).to receive(:each_line).and_wrap_original do |each, *args, &each_block|
          each.call(*args) { |line| (reads += 1) && each_block.call(line) }
        end
        block.call(stdin, stdout, stderr, waiter)
      end
    end

    tool.execute(pattern: 'needle')

    expect(reads).to eq(61)
  end

  it 'keeps one very long line from filling memory' do
    git_write(repo, 'minified.js', "needle #{'x' * 200_000}\n")
    git_commit(repo, 'minified')

    expect(tool.execute(pattern: 'needle', path: 'minified.js').lines.map(&:size).max).to be < 300
  end
end
