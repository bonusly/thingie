require "rails_helper"

RSpec.describe Search::Queries::DiscoverRoutes do
  it "parses every route from the real router" do
    routes = described_class.call

    expect(routes.size).to be > 20
    expect(routes.map(&:path)).to include("/tasks", "/tasks/:id", "/s/:token")
    expect(routes.map(&:path).uniq.size).to eq(routes.size)
  end

  it "captures the permission gate and component name" do
    tasks = described_class.call.find { |route| route.path == "/tasks" }
    expect(tasks).to have_attributes(name: "tasks.index", component: "TasksPage", permission: "tasks:read")
    expect(tasks).to be_gated
  end

  it "leaves the permission nil for open routes" do
    share = described_class.call.find { |route| route.path == "/s/:token" }
    expect(share.permission).to be_nil
    expect(share).not_to be_gated
  end

  it "handles a custom router file" do
    Tempfile.create(["router", ".tsx"]) do |file|
      file.write(<<~TSX)
        { path: "/a", name: "a", component: lazy(() => import("./pages/APage")), permission: "x:y" },
        {
          path: "/b",
          name: "b",
          component: lazy(() => import("./pages/BPage"))
        },
      TSX
      file.flush

      routes = described_class.call(router_path: file.path)
      expect(routes.map(&:path)).to eq(%w[/a /b])
      expect(routes.last.component).to eq("BPage")
    end
  end

  it "raises when the router is missing or has no routes" do
    expect { described_class.call(router_path: "/nowhere/app-router.tsx") }.to raise_error(Search::RouterMissing)

    Tempfile.create(["router", ".tsx"]) do |file|
      file.write("export const routes = [];\n")
      file.flush
      expect { described_class.call(router_path: file.path) }.to raise_error(Search::RouterEmpty)
    end
  end
end
