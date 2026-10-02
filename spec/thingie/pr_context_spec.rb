# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::PrContext do
  include GitRepo

  subject(:context) { described_class.new(changeset) }

  let(:repo) { Dir.mktmpdir }
  let(:changeset) do
    Thingie::Changeset.new(repo_path: repo, base_ref: 'base', exclude_files: ['config/locales/*'])
  end

  before do
    git(repo, 'init', '-q', '-b', 'main')
    git_write(repo, 'app/old.rb', "class Old\nend\n")
    git_write(repo, 'app/gone.rb', "class Gone\nend\n")
    git_commit(repo, 'base')
    git(repo, 'tag', 'base')
  end

  after { FileUtils.rm_rf(repo) }

  context 'with a typical PR' do
    before do
      git_write(repo, 'app/models/granola_gated.rb', <<~RUBY)
        module Concerns
          class GranolaGated
            REASONS = %w[a].freeze

            def self.call
            end

            def eligible?
            end
          end
        end
      RUBY
      git_write(repo, 'spec/factories/checkout_visits.rb', <<~RUBY)
        FactoryBot.define do
          factory :checkout_visit do
            trait :completed do
            end
          end
        end
      RUBY
      git_write(repo, 'config/locales/en.yml', "en:\n  refund:\n    unavailable: \"Gone\"\n")
      git_write(repo, 'app/old.rb', "class Old\n  def uses_it = GranolaGated.call\nend\n")
      FileUtils.rm(File.join(repo, 'app/gone.rb'))
      git_commit(repo, 'head')
    end

    it 'lists every touched path with its status, including files excluded from review' do
      expect(context.files).to contain_exactly(
        { path: 'app/models/granola_gated.rb', status: :added },
        { path: 'spec/factories/checkout_visits.rb', status: :added },
        { path: 'config/locales/en.yml', status: :added },
        { path: 'app/old.rb', status: :modified },
        { path: 'app/gone.rb', status: :deleted }
      )
    end

    it 'collects names defined on added lines, with their location' do
      expect(context.definitions.map { |d| [d[:name], d[:path], d[:line]] }).to include(
        ['GranolaGated', 'app/models/granola_gated.rb', 2],
        ['REASONS', 'app/models/granola_gated.rb', 3],
        ['call', 'app/models/granola_gated.rb', 5],
        ['eligible?', 'app/models/granola_gated.rb', 8],
        ['checkout_visit', 'spec/factories/checkout_visits.rb', 2],
        ['completed', 'spec/factories/checkout_visits.rb', 3],
        ['unavailable', 'config/locales/en.yml', 3],
        ['uses_it', 'app/old.rb', 2]
      )
    end

    it 'ignores definitions that were already there' do
      expect(context.definitions.map { |d| d[:name] }).not_to include('Old')
    end

    it 'renders the files and definitions for the prompt', :aggregate_failures do
      expect(context.to_s).to start_with("Files this PR touches:\n")
      expect(context.to_s).to include('- deleted app/gone.rb', "Names this PR defines on added lines:\n",
                                      '- GranolaGated (app/models/granola_gated.rb:2)')
    end
  end

  context 'when the PR defines nothing' do
    before do
      git_write(repo, 'README.md', "hi\n")
      git_commit(repo, 'head')
    end

    it 'lists only the files' do
      expect(context.to_s).to eq("Files this PR touches:\n- added README.md")
    end
  end

  context 'when the PR touches more files than the cap' do
    before do
      (described_class::MAX_FILES + 2).times { |i| git_write(repo, "f#{i}.txt", "x\n") }
      git_commit(repo, 'head')
    end

    it 'truncates the list and says how many were left out' do
      expect(context.to_s).to end_with('- ...and 2 more')
    end
  end

  context 'when reviewing the whole codebase' do
    let(:changeset) { Thingie::Changeset.new(repo_path: repo, all: true) }

    it 'has no PR to describe', :aggregate_failures do
      expect([context.files, context.definitions]).to eq([[], []])
      expect(context.to_s).to eq('')
    end
  end
end
