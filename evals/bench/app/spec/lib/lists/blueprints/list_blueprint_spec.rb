require "rails_helper"

RSpec.describe Lists::Blueprints::ListBlueprint do
  let(:list) { create(:list) }

  it "renders the base fields with string ids" do
    json = described_class.render_as_hash(list)
    expect(json).to include(id: list.id.to_s, owner_id: list.owner_id.to_s, state: "active", slug: list.slug)
    expect(json[:member_ids]).to eq([list.owner_id.to_s])
    expect(json).not_to have_key(:open_task_count)
  end

  it "adds counts in the with_counts view" do
    create(:task, company: list.company, list: list)
    create(:task, :done, company: list.company, list: list)
    create(:draft_task, :ready, company: list.company, list: list)

    json = described_class.render_as_hash(list, view: :with_counts)
    expect(json[:open_task_count]).to eq(1)
    expect(json[:ready_draft_count]).to eq(1)
  end
end
