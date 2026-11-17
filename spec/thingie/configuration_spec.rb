# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::Configuration do
  subject(:config) { described_class.new(root: tmp_dir) }

  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmp_dir) }

  it 'loads bundled defaults', :aggregate_failures do
    expect(config.dig('approve', 'enabled')).to be(false)
    expect(config.dig('approve', 'max_changes')).to eq(500)
    expect(config.dig('approve', 'protected_paths')).to eq(['.thingie/**/*'])
  end

  context 'with a project config file' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie', 'config.toml'), <<~TOML)
        [approve]
        enabled = true
        max_changes = 750
      TOML
    end

    it 'deep-merges it over the defaults', :aggregate_failures do
      expect(config.dig('approve', 'enabled')).to be(true)
      expect(config.dig('approve', 'max_changes')).to eq(750)
      expect(config.dig('approve', 'skip_label')).to eq('thingie-skip-approve')
    end
  end

  context 'with an unreadable project config file' do
    before do
      FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
      File.write(File.join(tmp_dir, '.thingie', 'config.toml'), '[approve')
    end

    it 'raises naming the file' do
      expect { config }.to raise_error(/Failed to load config from .*config\.toml/)
    end
  end

  context 'with ~/.thingie/.env' do
    let(:env_file) { File.join(tmp_dir, 'fake-home.env') }

    before do
      File.write(env_file, "GITHUB_TOKEN=from-dotenv-file\n")
      stub_const('Thingie::Configuration::USER_ENV_FILE', env_file)
    end

    it 'loads its variables into the environment' do
      config

      expect(Thingie::Env['GITHUB_TOKEN']).to eq('from-dotenv-file')
    end

    it 'leaves variables already set alone' do
      Thingie::Env['GITHUB_TOKEN'] = 'from-shell'
      config

      expect(Thingie::Env['GITHUB_TOKEN']).to eq('from-shell')
    end
  end

  context 'with explicit overrides' do
    subject(:config) { described_class.new(root: tmp_dir, overrides: { approve: { 'enabled' => true } }) }

    it 'applies them last' do
      expect(config.dig('approve', 'enabled')).to be(true)
    end
  end
end
