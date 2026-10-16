require "rails_helper"

RSpec.describe Lists::Commands::Deliver do
  include_context "with a list and a ready draft"

  it "stamps delivered_at and notifies the other members" do
    result = described_class.call(list: list, actor: admin)

    expect(result).to be_success
    expect(list.reload.delivered_at).to be_present
    expect(Notification.for_recipient(member).where(kind: "list_delivered").count).to eq(1)
    expect(Notification.for_recipient(admin).count).to eq(0)
  end

  it "enqueues draft conversion when ready drafts exist" do
    draft
    expect { described_class.call(list: list, actor: admin) }
      .to change(Lists::Jobs::ConvertDraftTasksJob.jobs, :size).by(1)
    expect(Lists::Jobs::ConvertDraftTasksJob.jobs.last["args"]).to eq([list.id.to_s, admin.id.to_s])
  end

  it "does not enqueue when there is nothing to convert" do
    expect { described_class.call(list: list, actor: admin) }
      .not_to change(Lists::Jobs::ConvertDraftTasksJob.jobs, :size)
  end

  it "dispatches the list.delivered webhook" do
    create(:webhook, company: company, events: %w[list.delivered])
    described_class.call(list: list, actor: admin)
    expect(WebhookDelivery.where(event: "list.delivered").count).to eq(1)
  end

  it "refuses non-members and archived lists" do
    expect(described_class.call(list: list, actor: outsider).error).to be_a(Lists::NotAMember)
    list.archive!
    expect(described_class.call(list: list, actor: admin).error).to be_a(Lists::Archived)
  end
end
