require "rails_helper"

RSpec.describe Search::Commands::UpsertRouteIndex do
  let(:now) { Time.utc(2026, 10, 16, 9) }

  def route(path, name: path.tr("/", "."), component: "Page", permission: nil)
    Search::Queries::DiscoverRoutes::Route.new(path: path, name: name, component: component, permission: permission)
  end

  it "writes one entry per route path" do
    result = described_class.call(routes: [route("/a", permission: "x"), route("/b")], now: now)

    expect(result.value).to eq(upserted: 2, dropped: 0)
    expect(RouteIndexEntry.where(path: "/a").first).to have_attributes(permission: "x", indexed_at: now)
  end

  it "keeps the first definition when a path repeats" do
    described_class.call(routes: [route("/a", name: "first"), route("/a", name: "second")], now: now)
    expect(RouteIndexEntry.count).to eq(1)
    expect(RouteIndexEntry.first.name).to eq("first")
  end

  it "drops unreadable entries" do
    result = described_class.call(routes: [route("a"), route("/b", name: ""), route("/c", component: nil), route("/d")], now: now)
    expect(result.value).to eq(upserted: 1, dropped: 3)
  end

  it "updates existing entries and prunes paths that disappeared" do
    create(:route_index_entry, path: "/old")
    existing = create(:route_index_entry, path: "/a", permission: "old")

    described_class.call(routes: [route("/a", permission: "new")], now: now)

    expect(existing.reload.permission).to eq("new")
    expect(RouteIndexEntry.where(path: "/old")).not_to exist
  end
end
