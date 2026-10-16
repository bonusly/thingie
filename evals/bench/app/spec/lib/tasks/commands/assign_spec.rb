require "rails_helper"

RSpec.describe Tasks::Commands::Assign do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: admin, assignee_ids: [admin.id]) }

  it "replaces the assignees and records added and removed" do
    result = described_class.call(task: task, actor: admin, assignee_ids: [member.id.to_s])

    expect(result).to be_success
    expect(task.reload.assignee_ids).to eq([member.id])
    expect(task.events.of_kind("assigned").first.data["user_ids"]).to eq([member.id.to_s])
    expect(task.events.of_kind("unassigned").first.data["user_ids"]).to eq([admin.id.to_s])
  end

  it "notifies newly assigned users only" do
    described_class.call(task: task, actor: admin, assignee_ids: [admin.id, member.id])
    expect(Notification.for_recipient(member).count).to eq(1)
    expect(Notification.for_recipient(admin).count).to eq(0)
  end

  it "rejects users who are not members" do
    result = described_class.call(task: task, actor: admin, assignee_ids: [outsider.id])
    expect(result).to be_failure
    expect(result.error).to include("not members")
  end

  it "deduplicates ids" do
    described_class.call(task: task, actor: admin, assignee_ids: [member.id, member.id.to_s])
    expect(task.reload.assignee_ids).to eq([member.id])
  end
end
