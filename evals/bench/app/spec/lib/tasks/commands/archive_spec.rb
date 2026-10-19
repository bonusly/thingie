require "rails_helper"

RSpec.describe Tasks::Commands::Archive do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: admin) }

  it "archives the task and drops pending reminders" do
    create(:reminder, company: company, task: task, user: member)
    sent = create(:reminder, :sent, company: company, task: task, user: member)

    result = described_class.call(task: task, actor: admin)

    expect(result).to be_success
    expect(task.reload).to be_archived
    expect(task.reminders.to_a).to eq([sent])
  end

  it "works from done as well" do
    task.complete!
    expect(described_class.call(task: task, actor: admin)).to be_success
  end

  it "accepts a nil actor for scheduled archiving" do
    described_class.call(task: task, actor: nil)
    expect(task.events.of_kind("archived").first.actor_id).to be_nil
  end

  it "fails when already archived" do
    task.archive!
    expect(described_class.call(task: task, actor: admin)).to be_failure
  end
end
