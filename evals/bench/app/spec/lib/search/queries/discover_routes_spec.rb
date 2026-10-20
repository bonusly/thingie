require "rails_helper"

RSpec.describe Search::Queries::DiscoverRoutes do
  it "parses every route from the real router, static paths first" do
    routes = described_class.call

    expect(routes.size).to be > 20
    expect(routes.map(&:path)).to include("/tasks", "/tasks/:id", "/admin/companies", "/s/:token")
    expect(routes.take_while { |route| !route.dynamic? }.size).to eq(routes.count { |route| !route.dynamic? })
  end

  it "resolves permission constants and flags through the router's imports" do
    routes = described_class.call
    tasks = routes.find { |route| route.path == "/tasks" }
    ledger = routes.find { |route| route.path == "/points/ledger" }

    expect(tasks).to have_attributes(name: "tasks.index", component: "TasksPage", permission: "tasks:read", flag: nil)
    expect(ledger).to have_attributes(permission: "points:read", flag: "points_ledger")
    expect(ledger).to be_flagged
  end

  it "treats a requireAdmin wrapper as a staff gate" do
    companies = described_class.call.find { |route| route.path == "/admin/companies" }
    expect(companies).to have_attributes(component: "AdminCompaniesPage", permission: "admin:staff")
  end

  it "leaves the permission nil for open routes" do
    share = described_class.call.find { |route| route.path == "/s/:token" }
    expect(share.permission).to be_nil
    expect(share).not_to be_gated
  end

  describe "with a custom router" do
    def discover(source)
      Tempfile.create(["router", ".tsx"]) do |file|
        file.write(source)
        file.flush
        described_class.call(router_path: file.path, tsconfig_path: "/nowhere/tsconfig.json")
      end
    end

    it "applies the outermost gate to nested children and lists static paths first" do
      routes = discover(<<~TSX)
        export const routes = [
          { path: "/tasks/new", name: "tasks.new", component: lazy(() => import("./pages/TaskDetailPage")) },
          { path: "/tasks/:id", name: "tasks.show", component: lazy(() => import("./pages/TaskDetailPage")), permission: "tasks:read" },
          {
            path: "/lists",
            name: "lists.layout",
            component: lazy(() => import("./pages/ListsLayout")),
            permission: "lists:read",
            flag: "lists_v2",
            children: [
              { path: "/lists/:id/drafts", name: "lists.drafts", component: lazy(() => import("./pages/DraftTasksPage")), permission: "drafts:read" },
            ],
          },
        ];
      TSX

      expect(routes.map(&:path)).to eq(%w[/tasks/new /lists /tasks/:id /lists/:id/drafts])
      expect(routes.find { |route| route.path == "/tasks/new" }).not_to be_gated
      expect(routes.last).to have_attributes(permission: "lists:read", flag: "lists_v2", component: "DraftTasksPage")
    end

    it "keeps an entry whose component it cannot read, without a component" do
      routes = discover(<<~TSX)
        export const routes = [
          { path: "/a", name: "a", component: lazy(() => import("./pages/APage").then((m) => ({ default: m.APage }))) },
        ];
      TSX

      expect(routes.first).to have_attributes(path: "/a", name: "a", component: nil)
      expect(routes.first).not_to be_readable
    end
  end

  it "raises when the router is missing, unreadable, or has no routes" do
    expect { described_class.call(router_path: "/nowhere/app-router.tsx") }.to raise_error(Search::RouterMissing)

    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(Rails.root.join(described_class::DEFAULT_ROUTER)).and_raise(Errno::EACCES)
    expect { described_class.call }.to raise_error(Search::FetchFailed)

    Tempfile.create(["router", ".tsx"]) do |file|
      file.write("export const routes = [];\n")
      file.flush
      expect { described_class.call(router_path: file.path) }.to raise_error(Search::RouterEmpty)
    end
  end
end
