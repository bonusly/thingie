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

    it 'renders the file list for the prompt', :aggregate_failures do
      expect(context.to_s).to start_with('Files this PR touches')
      expect(context.to_s).to include('- added app/models/granola_gated.rb', '- deleted app/gone.rb',
                                      '- added config/locales/en.yml')
    end

    it 'lists paths only, not what the files define' do
      expect(context.to_s).not_to include('GranolaGated', 'unavailable')
    end
  end

  context 'when the PR touches a single file' do
    before do
      git_write(repo, 'README.md', "hi\n")
      git_commit(repo, 'head')
    end

    it 'lists just that file' do
      expect(context.to_s).to end_with("\n- added README.md")
    end
  end

  context 'when several files share a directory and status' do
    before do
      %w[cs de en].each { |locale| git_write(repo, "config/locales/#{locale}.yml", "#{locale}:\n") }
      git_write(repo, 'app/views/_a.html.erb', "a\n")
      git_write(repo, 'app/views/_b.html.erb', "b\n")
      git_write(repo, 'Gemfile', "source 'x'\n")
      git_write(repo, 'Gemfile.lock', "GEM\n")
      git_commit(repo, 'head')
    end

    it 'collapses them into one brace line, keeping a shared extension outside', :aggregate_failures do
      expect(context.to_s.lines(chomp: true)).to include('- added config/locales/{cs,de,en}.yml',
                                                         '- added app/views/{_a,_b}.html.erb',
                                                         '- added {Gemfile,Gemfile.lock}')
      expect(context.to_s).to start_with("Files this PR touches (`dir/{a,b}.rb` means dir/a.rb and dir/b.rb):\n")
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
      expect(context.files).to eq([])
      expect(context.to_s).to eq('')
    end
  end
end
