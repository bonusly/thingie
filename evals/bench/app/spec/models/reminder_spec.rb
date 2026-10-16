require "rails_helper"

RSpec.describe Reminder do
  it "rejects a reminder in the past on create" do
    reminder = build(:reminder, remind_at: 1.minute.ago)
    expect(reminder).not_to be_valid
    expect(reminder.errors[:remind_at]).to be_present
  end

  it "requires a known channel" do
    expect(build(:reminder, channel: "sms")).not_to be_valid
  end

  describe ".due" do
    it "returns unsent reminders whose time has passed" do
      reminder = create(:reminder, remind_at: 1.hour.from_now)
      sent = create(:reminder, :sent, remind_at: 1.hour.from_now)

      travel 2.hours do
        expect(described_class.due.to_a).to eq([reminder])
        expect(described_class.due).not_to include(sent)
      end
    end
  end

  describe "#mark_sent!" do
    it "stamps sent_at" do
      reminder = create(:reminder)
      reminder.mark_sent!
      expect(reminder.reload.sent_at).to be_present
      expect(reminder.due?(now: 2.hours.from_now)).to be(false)
    end
  end
end
