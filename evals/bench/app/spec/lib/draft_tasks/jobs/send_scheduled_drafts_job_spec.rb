require "rails_helper"

RSpec.describe DraftTasks::Jobs::SendScheduledDraftsJob do
  include_context "with a list and a ready draft"

  it "sends ready drafts whose schedule has passed" do
    draft.update!(scheduled_for: 10.minutes.ago)
    future = create(:draft_task, :ready, company: company, list: list, author: member, scheduled_for: 1.day.from_now)

    described_class.new.perform

    expect(draft.reload).to be_sent
    expect(future.reload).to be_ready
  end

  it "ignores drafting drafts even when scheduled" do
    drafting = create(:draft_task, company: company, list: list, author: member, scheduled_for: 1.hour.ago)
    described_class.new.perform
    expect(drafting.reload).to be_drafting
  end

  it "uses the given time when provided" do
    draft.update!(scheduled_for: 2.hours.from_now)
    described_class.new.perform(3.hours.from_now.iso8601)
    expect(draft.reload).to be_sent
  end
end
