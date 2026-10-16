# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::GitHub::Context do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:context) { described_class.new(repo: 'acme/app', event_path: event_path, workflow_pr: nil) }

  let(:event_path) { File.join(Dir.mktmpdir, 'event.json') }

  after { FileUtils.rm_rf(File.dirname(event_path)) }

  context 'with a pull request event' do
    before do
      File.write(event_path, JSON.generate('pull_request' => { 'number' => 7, 'title' => 'Gate granola',
                                                               'body' => 'Behind a flag.' }))
    end

    it 'reads the number, title and description from the payload', :aggregate_failures do
      expect(context.pr_number).to eq(7)
      expect(context.pr_title).to eq('Gate granola')
      expect(context.pr_body).to eq('Behind a flag.')
    end
  end

  context 'with a pull request that has no description' do
    before { File.write(event_path, JSON.generate('pull_request' => { 'number' => 7, 'title' => 'Gate granola' })) }

    it 'has a title and no body', :aggregate_failures do
      expect(context.pr_title).to eq('Gate granola')
      expect(context.pr_body).to be_nil
    end
  end

  context 'without an event payload' do
    it 'has no pull request', :aggregate_failures do
      expect(context.pr_number).to be_nil
      expect(context.pr_title).to be_nil
      expect(context.pr_body).to be_nil
    end
  end
end
