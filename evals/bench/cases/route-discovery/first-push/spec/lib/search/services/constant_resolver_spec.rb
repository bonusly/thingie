require "rails_helper"

RSpec.describe Search::Services::ConstantResolver do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      FileUtils.mkdir_p(File.join(dir, "app/javascript"))
      File.write(File.join(dir, "tsconfig.json"), { compilerOptions: { paths: { "@app/flags" => ["app/javascript/flags.ts"] } } }.to_json)
      File.write(File.join(dir, "app/javascript/flags.ts"), "export const FLAGS = {\n  BETA: \"beta\",\n} as const;\n")
      File.write(File.join(dir, "app/javascript/permissions.ts"), "export const PERMISSIONS = {\n  TASKS_READ: \"tasks:read\",\n} as const;\n")
      example.run
    end
  end

  let(:router) do
    <<~TSX
      import { PERMISSIONS } from "./permissions";
      import type { Permission } from "./permissions";
      import { FLAGS } from "@app/flags";
    TSX
  end

  subject(:resolver) do
    described_class.new(
      source: router,
      router_path: File.join(@dir, "app/javascript/app-router.tsx"),
      tsconfig_path: File.join(@dir, "tsconfig.json")
    )
  end

  it "resolves a relative import" do
    expect(resolver.call("PERMISSIONS.TASKS_READ")).to eq("tasks:read")
  end

  it "resolves a tsconfig path alias" do
    expect(resolver.call("FLAGS.BETA")).to eq("beta")
  end

  it "raises for a key, namespace or import it cannot find" do
    expect { resolver.call("FLAGS.GAMMA") }.to raise_error(Search::UnresolvedConstant)
    expect { resolver.call("ROLES.ADMIN") }.to raise_error(Search::UnresolvedConstant)
    expect { resolver.call("beta") }.to raise_error(Search::UnresolvedConstant)
  end
end
