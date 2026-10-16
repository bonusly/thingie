require "rails_helper"

RSpec.describe Tasks::Commands::Complete do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: admin, assignee_ids: [member.id]) }

  it "marks the task done and notifies the author" do
    result = described_class.call(task: task, actor: member)

    expect(result).to be_success
    expect(task.reload).to be_done
    expect(Notification.for_recipient(admin).where(kind: "task_completed").count).to eq(1)
  end

  it "does not notify the author when they completed it themselves" do
    described_class.call(task: task, actor: admin)
    expect(Notification.for_recipient(admin).count).to eq(0)
  end

  it "dispatches the task.completed webhook" do
    create(:webhook, company: company, events: %w[task.completed])
    described_class.call(task: task, actor: member)
    expect(WebhookDelivery.where(event: "task.completed").count).to eq(1)
  end

  it "fails when the task is not open" do
    task.complete!
    result = described_class.call(task: task, actor: member)
    expect(result).to be_failure
    expect(result.error).to be_a(Tasks::InvalidTransition)
  end
end
