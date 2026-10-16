require "rails_helper"

RSpec.describe Tasks::Jobs::SendDueRemindersJob do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: admin, due_on: 1.day.from_now.to_date) }

  it "notifies and marks due reminders as sent" do
    reminder = create(:reminder, company: company, task: task, user: member, remind_at: 1.hour.from_now)
    future = create(:reminder, company: company, task: task, user: member, remind_at: 1.day.from_now)

    travel 2.hours do
      described_class.new.perform
    end

    expect(reminder.reload.sent_at).to be_present
    expect(future.reload.sent_at).to be_nil
    expect(Notification.for_recipient(member).where(kind: "task_due_soon").count).to eq(1)
  end

  it "emails when the channel is email" do
    create(:reminder, :email, company: company, task: task, user: member, remind_at: 1.hour.from_now)

    travel 2.hours do
      expect { described_class.new.perform }.to change(ActionMailer::Base.deliveries, :size).by(1)
    end
  end

  it "skips archived tasks without notifying" do
    reminder = create(:reminder, company: company, task: task, user: member, remind_at: 1.hour.from_now)
    task.archive!

    described_class.new.perform(3.hours.from_now.iso8601)

    expect(reminder.reload.sent_at).to be_present
    expect(Notification.count).to eq(0)
  end
end
