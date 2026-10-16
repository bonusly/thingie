require "rails_helper"

RSpec.describe Tasks::Commands::Update do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: member, title: "Old") }

  it "updates permitted fields and tracks which changed" do
    result = described_class.call(task: task, actor: member, attrs: { title: "New", due_on: Date.new(2026, 12, 1) })

    expect(result).to be_success
    expect(task.reload.title).to eq("New")
    event = task.events.of_kind("updated").first
    expect(event.data["fields"]).to match_array(%w[title due_on])
  end

  it "ignores fields outside the permitted list" do
    described_class.call(task: task, actor: member, attrs: { points: 40, state: "done" })
    expect(task.reload.points).to eq(0)
    expect(task).to be_open
  end

  it "is a no-op without changes" do
    result = described_class.call(task: task, actor: member, attrs: { title: "Old" })
    expect(result).to be_success
    expect(task.events.count).to eq(0)
  end

  it "refuses to edit an archived task" do
    task.archive!
    result = described_class.call(task: task, actor: member, attrs: { title: "New" })
    expect(result).to be_failure
    expect(result.error).to be_a(Tasks::InvalidTransition)
  end
end
