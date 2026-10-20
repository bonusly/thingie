require "rails_helper"

RSpec.describe Search::Commands::UpsertRouteIndex do
  let(:now) { Time.utc(2026, 10, 16, 9) }

  def route(path, name: path.tr("/", "."), component: "Page", permission: nil, flag: nil)
    Search::Queries::DiscoverRoutes::Route.new(path: path, name: name, component: component, permission: permission, flag: flag)
  end

  it "writes one entry per route path with its gate and flag" do
    result = described_class.call(routes: [route("/a", permission: "x", flag: "f"), route("/b")], now: now)

    expect(result.value).to eq(upserted: 2, unreadable: 0, pruned: 0)
    expect(RouteIndexEntry.where(path: "/a").first).to have_attributes(permission: "x", flag: "f", unreadable: false, indexed_at: now)
  end

  it "keeps the last definition when a path repeats" do
    described_class.call(routes: [route("/a", name: "layout"), route("/a", name: "index")], now: now)
    expect(RouteIndexEntry.count).to eq(1)
    expect(RouteIndexEntry.first.name).to eq("index")
  end

  it "keeps a static path and a dynamic one that would also match it as separate entries" do
    described_class.call(routes: [route("/tasks/new"), route("/tasks/:id", permission: "tasks:read")], now: now)
    expect(RouteIndexEntry.where(path: "/tasks/new").first).not_to be_gated
    expect(RouteIndexEntry.where(path: "/tasks/:id").first).to be_gated
  end

  it "marks an existing entry unreadable instead of pruning it" do
    existing = create(:route_index_entry, path: "/a", permission: "x")

    result = described_class.call(routes: [route("/a", component: nil), route("/b")], now: now)

    expect(result.value).to eq(upserted: 1, unreadable: 1, pruned: 0)
    expect(existing.reload).to have_attributes(permission: "x", unreadable: true, indexed_at: now)
  end

  it "writes nothing for unreadable routes that were never indexed" do
    result = described_class.call(routes: [route("a"), route("/b", name: ""), route("/c", component: nil), route("/d")], now: now)
    expect(result.value).to eq(upserted: 1, unreadable: 0, pruned: 0)
    expect(RouteIndexEntry.pluck(:path)).to eq(["/d"])
  end

  it "updates existing entries and prunes paths that disappeared" do
    create(:route_index_entry, path: "/old")
    existing = create(:route_index_entry, path: "/a", permission: "old")

    result = described_class.call(routes: [route("/a", permission: "new")], now: now)

    expect(result.value[:pruned]).to eq(1)
    expect(existing.reload.permission).to eq("new")
    expect(RouteIndexEntry.where(path: "/old")).not_to exist
  end
end
