# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::RiskQuestions do
  subject(:risk_questions) { described_class.new(ratings) }

  let(:tmp_dir) { Dir.mktmpdir }
  let(:ratings) { Thingie::Configuration.new(root: tmp_dir).dig('change_risk', 'ratings') }

  after { FileUtils.rm_rf(tmp_dir) }

  describe '#rating_for with the default floors' do
    {
      0.0 => 'trivial', 0.16 => 'trivial', 0.17 => 'routine', 0.49 => 'routine', 0.5 => 'risky',
      0.8 => 'risky', 0.81 => 'critical', 1.0 => 'critical'
    }.each do |overall, rating|
      it "rates an overall of #{overall} as #{rating}" do
        expect(risk_questions.rating_for(overall)).to eq(rating)
      end
    end
  end

  it 'sends each level, lowest first, as a criterion of the overall question' do
    ratings['critical'] = { 'floor' => 0.9, 'description' => '  outage risk  ' }

    expect(risk_questions.questions[:overall][:criteria].map { |criterion| criterion.split(':').first })
      .to eq(%w[Trivial Routine Risky Critical])
    expect(risk_questions.questions[:overall][:criteria].last).to eq('Critical: outage risk')
  end

  it 'rates by configured floors' do
    ratings['critical']['floor'] = 0.9

    expect(risk_questions.rating_for(0.85)).to eq('risky')
  end

  it 'keeps the default levels a project config does not override' do
    FileUtils.mkdir_p(File.join(tmp_dir, '.thingie'))
    File.write(File.join(tmp_dir, '.thingie', 'config.toml'), "[change_risk.ratings.critical]\nfloor = 0.9\n")

    expect(risk_questions.rating_for(0.85)).to eq('risky')
    expect(risk_questions.rating_for(0.5)).to eq('risky')
    expect(risk_questions.questions[:overall][:criteria].last).to start_with('Critical: changes authentication')
  end

  {
    'an unknown level' => [->(r) { r['severe'] = r['critical'] }, /unknown level\(s\) severe/],
    'a missing level' => [->(r) { r.delete('risky') }, /ratings\.risky must be a table/],
    'a floor above 1' => [->(r) { r['critical']['floor'] = 1.5 }, /critical\.floor must be a number from 0 to 1/],
    'a non-numeric floor' => [->(r) { r['routine']['floor'] = 'low' }, /routine\.floor must be a number/],
    'a blank description' => [->(r) { r['risky']['description'] = ' ' }, /risky\.description must be a non-blank/],
    'floors out of order' => [->(r) { r['risky']['floor'] = 0.9 }, /floors must rise.*risky = 0\.9, critical = 0\.81/],
    'a trivial floor above 0' => [->(r) { r['trivial']['floor'] = 0.1 }, /floors must rise from trivial = 0/]
  }.each do |description, (change, message)|
    it "rejects #{description}" do
      change.call(ratings)

      expect { risk_questions }.to raise_error(Thingie::ConfigurationError, message)
    end
  end
end
