# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Thingie::SkillCatalog do
  let(:tmp_dir) { Dir.mktmpdir }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe '.tool' do
    it 'returns nil when there are no skills' do
      config = Thingie::Configuration.new(root: tmp_dir, overrides: { skill_directories: [] })
      expect(described_class.tool(config)).to be_nil
    end

    context 'with skill fragments' do
      before do
        FileUtils.mkdir_p(File.join(tmp_dir, '.cursor'))
        File.write(File.join(tmp_dir, '.cursor', 'rails.md'), "# Rails rules\nAlways use strong params.")
      end

      it 'returns a SkillTool whose description lists the skill without its full body', :aggregate_failures do
        tool = described_class.tool(Thingie::Configuration.new(root: tmp_dir))

        expect(tool).to be_a(RubyLLM::Skills::SkillTool)
        expect(tool.description).to include('.cursor/rails')
        expect(tool.description).to include('Rails rules')
        expect(tool.description).not_to include('Always use strong params.')
      end

      it 'loads the full skill content on demand' do
        tool = described_class.tool(Thingie::Configuration.new(root: tmp_dir))
        expect(tool.execute(command: '.cursor/rails')).to include('Always use strong params.')
      end
    end

    context 'with same-named skills across directories' do
      before do
        %w[.agents .cursor].each do |dir|
          FileUtils.mkdir_p(File.join(tmp_dir, dir))
          File.write(File.join(tmp_dir, dir, 'rails_rules.md'), "#{dir} content")
        end
      end

      it 'namespaces skill names by source directory so both remain findable', :aggregate_failures do
        catalog = described_class.new(Thingie::Configuration.new(root: tmp_dir))

        expect(catalog.list.map(&:name)).to contain_exactly('.agents/rails_rules', '.cursor/rails_rules')
        expect(catalog.find('.agents/rails_rules').content).to eq('.agents content')
        expect(catalog.find('.cursor/rails_rules').content).to eq('.cursor content')
      end
    end

    context 'with <name>/SKILL.md skills that have front matter' do
      before do
        %w[forms styling].each do |name|
          dir = File.join(tmp_dir, '.agents', 'skills', name)
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, 'SKILL.md'), "---\nname: #{name}\ndescription: About #{name}.\n---\n\n#{name} body")
        end
      end

      it 'names and describes each skill from its front matter so each is findable', :aggregate_failures do
        config = Thingie::Configuration.new(root: tmp_dir, overrides: { skill_directories: ['.agents/skills'] })
        catalog = described_class.new(config)

        expect(catalog.list.map { |s| [s.name, s.description] })
          .to contain_exactly(['skills/forms', 'About forms.'], ['skills/styling', 'About styling.'])
        expect(catalog.find('skills/forms').content).to include('forms body')
        expect(catalog.find('skills/styling').content).to include('styling body')
      end
    end
  end
end
