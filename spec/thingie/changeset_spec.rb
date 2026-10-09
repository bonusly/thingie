# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::Changeset do
  include GitRepo

  let(:repo) { Dir.mktmpdir }

  before do
    git(repo, 'init', '-q', '-b', 'main')
    git_write(repo, 'app/old.rb', "one\ntwo\nthree\n")
    git_write(repo, 'config/locales/en.yml', "a: 1\n")
    git_commit(repo, 'base')
    git(repo, 'tag', 'base')
    git_write(repo, 'app/old.rb', "one\nTWO\nthree\nfour\n")
    git_write(repo, 'config/locales/en.yml', "a: 1\nb: 2\nc: 3\n")
    git_commit(repo, 'change')
  end

  after { FileUtils.rm_rf(repo) }

  describe '#changed_line_count' do
    it 'counts lines added plus lines removed, in files that are excluded from review too' do
      changeset = described_class.new(repo_path: repo, base_ref: 'base', exclude_files: ['config/locales/*'])

      # app/old.rb: "two" -> "TWO" is 1 added + 1 removed, "four" is 1 added; en.yml: 2 added.
      expect(changeset.changed_line_count).to eq(5)
    end

    it 'is nil in --all mode, where there is no PR to size' do
      expect(described_class.new(repo_path: repo, all: true).changed_line_count).to be_nil
    end
  end
end
