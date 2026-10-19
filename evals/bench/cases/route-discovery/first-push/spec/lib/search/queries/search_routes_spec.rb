require "rails_helper"

RSpec.describe Search::Queries::SearchRoutes do
  include_context "with a company and members"

  let!(:home) { create(:route_index_entry, path: "/", name: "home") }
  let!(:tasks) { create(:route_index_entry, :gated, path: "/tasks", name: "tasks.index") }
  let!(:members) { create(:route_index_entry, path: "/members", name: "members.index", permission: "members:manage") }
  let!(:staff_page) { create(:route_index_entry, :staff_only, path: "/admin", name: "admin.index") }
  let!(:ledger) { create(:route_index_entry, :flagged, path: "/points/ledger", name: "points.ledger") }

  def search(user, q: nil)
    described_class.call(user: user, company: company, membership: user.membership_for(company), q: q).to_a
  end

  it "shows a member only routes their role can open" do
    expect(search(member)).to eq([home, tasks])
  end

  it "shows admins their management pages" do
    expect(search(admin)).to eq([home, members, tasks])
  end

  it "shows staff everything their company's flags allow" do
    staff = create(:user, :staff)
    create(:membership, company: company, user: staff)
    expect(search(staff)).to eq([home, staff_page, members, tasks])
  end

  it "includes flagged routes once the company enables the flag" do
    company.update!(settings: { "flags" => ["points_ledger"] })
    expect(search(member)).to eq([home, ledger, tasks])
  end

  it "still serves entries the last reindex could not read" do
    tasks.update!(unreadable: true)
    expect(search(member)).to include(tasks)
  end

  it "filters by name or path" do
    expect(search(member, q: "task")).to eq([tasks])
  end
end
