# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::TestPair do
  include GitRepo

  subject(:pair) { described_class.new(changeset) }

  let(:repo) { Dir.mktmpdir }
  let(:changeset) { Thingie::Changeset.new(repo_path: repo, base_ref: 'base') }

  before do
    git(repo, 'init', '-q', '-b', 'main')
    git_write(repo, 'app/lib/cards/deliver.rb', "class Deliver\n  def call = enqueue\nend\n")
    git_write(repo, 'spec/lib/cards/deliver_spec.rb', "RSpec.describe Deliver do\nend\n")
    git_write(repo, 'lib/thingie/report.rb', "class Report\nend\n")
    git_write(repo, 'spec/thingie/report_spec.rb', "RSpec.describe Report do\nend\n")
    git_commit(repo, 'base')
    git(repo, 'tag', 'base')
  end

  after { FileUtils.rm_rf(repo) }

  context 'when a spec and the code it tests both change' do
    before do
      git_write(repo, 'app/lib/cards/deliver.rb', "class Deliver\n  def call = enqueue || log\nend\n")
      git_write(repo, 'spec/lib/cards/deliver_spec.rb', "RSpec.describe Deliver do\n  it 'logs' do\n  end\nend\n")
      git_commit(repo, 'head')
    end

    it 'gives the spec its subject, whole, with what to report', :aggregate_failures do
      section = pair.section_for('spec/lib/cards/deliver_spec.rb')
      expect(section).to start_with('The code these tests exercise: app/lib/cards/deliver.rb, also changed in this PR.')
      expect(section).to include('Report only problems with the tests', 'do not report it here')
      expect(section).to include("class Deliver\n  def call = enqueue || log\nend\n")
    end

    it 'gives the subject the diff of its spec', :aggregate_failures do
      section = pair.section_for('app/lib/cards/deliver.rb')
      expect(section).to start_with('The tests for this file, changed in this PR: spec/lib/cards/deliver_spec.rb.')
      expect(section).to include("+  it 'logs' do")
      expect(section).not_to include("RSpec.describe Deliver do\nend\n")
    end
  end

  context 'when only the spec changes' do
    before do
      git_write(repo, 'spec/lib/cards/deliver_spec.rb', "RSpec.describe Deliver do\n  it 'runs' do\n  end\nend\n")
      git_commit(repo, 'head')
    end

    it 'still gives the spec its subject, without saying it changed' do
      expect(pair.section_for('spec/lib/cards/deliver_spec.rb'))
        .to start_with('The code these tests exercise: app/lib/cards/deliver.rb.')
    end
  end

  context 'when only the code changes' do
    before do
      git_write(repo, 'app/lib/cards/deliver.rb', "class Deliver\n  def call = enqueue || log\nend\n")
      git_commit(repo, 'head')
    end

    it 'has nothing to add, since the spec is unchanged' do
      expect(pair.section_for('app/lib/cards/deliver.rb')).to eq('')
    end
  end

  context 'with a gem layout' do
    before do
      git_write(repo, 'lib/thingie/report.rb', "class Report\n  def to_s = ''\nend\n")
      git_write(repo, 'spec/thingie/report_spec.rb', "RSpec.describe Report do\n  it 'renders' do\n  end\nend\n")
      git_commit(repo, 'head')
    end

    it 'pairs spec/thingie with lib/thingie', :aggregate_failures do
      expect(pair.subject_for('spec/thingie/report_spec.rb')).to eq('lib/thingie/report.rb')
      expect(pair.spec_for('lib/thingie/report.rb')).to eq('spec/thingie/report_spec.rb')
    end
  end

  context 'with files that have no pair' do
    before do
      git_write(repo, 'spec/factories/cards.rb', "FactoryBot.define do\nend\n")
      git_write(repo, 'spec/lib/cards/orphan_spec.rb', "RSpec.describe 'orphan' do\nend\n")
      git_write(repo, 'config/routes.rb', "Rails.application.routes.draw do\nend\n")
      git_commit(repo, 'head')
    end

    it 'adds nothing', :aggregate_failures do
      expect(pair.section_for('spec/factories/cards.rb')).to eq('')
      expect(pair.section_for('spec/lib/cards/orphan_spec.rb')).to eq('')
      expect(pair.section_for('config/routes.rb')).to eq('')
    end
  end

  context 'when the subject is longer than the cap' do
    before do
      git_write(repo, 'app/lib/cards/deliver.rb', "class Deliver\n#{"  # line\n" * described_class::MAX_LINES}end\n")
      git_write(repo, 'spec/lib/cards/deliver_spec.rb', "RSpec.describe Deliver do\n  it 'x' do\n  end\nend\n")
      git_commit(repo, 'head')
    end

    it 'cuts it and says so', :aggregate_failures do
      section = pair.section_for('spec/lib/cards/deliver_spec.rb')
      expect(section).to end_with("[cut after #{described_class::MAX_LINES} lines]")
      expect(section).not_to end_with("end\n")
    end
  end

  context 'when the subject has few lines but a very long one' do
    before do
      long = 'x' * described_class::MAX_BYTES
      git_write(repo, 'app/lib/cards/deliver.rb', "class Deliver\n  DATA = '#{long}'\nend\n")
      git_write(repo, 'spec/lib/cards/deliver_spec.rb', "RSpec.describe Deliver do\n  it 'x' do\n  end\nend\n")
      git_commit(repo, 'head')
    end

    it 'cuts at the byte cap instead', :aggregate_failures do
      section = pair.section_for('spec/lib/cards/deliver_spec.rb')
      expect(section).to end_with("class Deliver\n[cut after 1 lines]")
      expect(section.bytesize).to be < described_class::MAX_BYTES
    end
  end

  context 'when the PR deletes a spec' do
    before do
      FileUtils.rm(File.join(repo, 'spec/lib/cards/deliver_spec.rb'))
      git_commit(repo, 'head')
    end

    it 'has no tests left to review against the subject' do
      expect(pair.section_for('spec/lib/cards/deliver_spec.rb')).to eq('')
    end
  end

  context 'when reviewing the whole codebase' do
    let(:changeset) { Thingie::Changeset.new(repo_path: repo, all: true) }

    it 'has no diff to pair against' do
      expect(pair.section_for('spec/lib/cards/deliver_spec.rb')).to eq('')
    end
  end
end
