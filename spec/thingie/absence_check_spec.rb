# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Thingie::AbsenceCheck do
  subject(:check) { described_class.new(pr_context) }

  let(:pr_context) do
    instance_double(Thingie::PrContext,
                    files: [
                      { path: 'app/models/concerns/granola_gated.rb', status: :added },
                      { path: 'app/views/shared/_tile_content.html.erb', status: :added },
                      { path: 'app/views/shared/_old_tile.html.erb', status: :deleted }
                    ],
                    definitions: [
                      { name: 'Concerns::GranolaGated', path: 'app/models/concerns/granola_gated.rb', line: 2 },
                      { name: 'checkout_visit', path: 'spec/factories/checkout_visits.rb', line: 2 },
                      { name: 'unavailable', path: 'config/locales/en.yml', line: 3 }
                    ])
  end

  def issue(title, details = 'd')
    Thingie::Issue.from_hash('title' => title, 'details' => details, 'severity' => 1, 'confidence' => 1,
                             'tags' => ['bug'], 'file' => 'app/old.rb', 'affected_lines' => [{ 'start_line' => 1 }])
  end

  def dropped_names(*issues)
    check.call(issues).last.map(&:last)
  end

  it 'drops an undefined-constant claim about a class the PR adds' do
    expect(dropped_names(issue('`GranolaGated` is not defined anywhere'))).to eq(['GranolaGated'])
  end

  it 'reads names the model left unquoted' do
    finding = issue('GranolaGated constant is not resolvable from GetGranolaMeetings',
                    'No definition was found; class loading will fail with NameError: uninitialized constant.')
    expect(dropped_names(finding)).to eq(['GranolaGated'])
  end

  it 'matches a namespaced name against its last segment' do
    expect(dropped_names(issue('Uninitialized constant', '`Concerns::GranolaGated` does not exist'))).not_to be_empty
  end

  it 'drops a missing-factory claim about a factory the PR adds' do
    expect(dropped_names(issue('Spec depends on undefined factory `:checkout_visit`'))).to eq([':checkout_visit'])
  end

  it 'drops a missing-translation claim about a key the PR adds' do
    expect(dropped_names(issue('Translation key `.unavailable` is missing'))).to eq(['.unavailable'])
  end

  it 'drops a missing-partial claim about a partial the PR adds' do
    expect(dropped_names(issue('Partial `shared/tile_content` not found'))).to eq(['shared/tile_content'])
  end

  it 'keeps a missing-partial claim about a partial the PR deletes' do
    expect(dropped_names(issue('Partial `shared/old_tile` not found'))).to be_empty
  end

  it 'keeps an absence claim whose names the PR does not add' do
    expect(dropped_names(issue('`TotallyAbsent` is not defined'))).to be_empty
  end

  it 'keeps a "missing" finding about something other than a definition' do
    expect(dropped_names(issue('Missing nil check on `user`'))).to be_empty
  end

  it 'keeps a finding that names a PR-added class without claiming it is absent' do
    expect(dropped_names(issue('`GranolaGated` swallows the API error'))).to be_empty
  end

  it 'returns kept findings in their original order' do
    first = issue('Race in `skip`')
    second = issue('`GranolaGated` is undefined')
    third = issue('Wrong flag')
    expect(check.call([first, second, third]).first).to eq([first, third])
  end
end
