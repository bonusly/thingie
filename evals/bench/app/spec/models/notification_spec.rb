require "rails_helper"

RSpec.describe Notification do
  it "rejects unknown kinds" do
    expect(build(:notification, kind: "poke")).not_to be_valid
  end

  describe "#mark_read!" do
    it "stamps read_at once and leaves the first stamp alone" do
      notification = create(:notification)
      notification.mark_read!
      first = notification.read_at
      travel 1.minute do
        notification.mark_read!
      end
      expect(notification.reload.read_at).to be_within(1.second).of(first)
    end
  end

  describe "#subject" do
    it "loads the referenced record" do
      task = create(:task)
      notification = create(:notification, company: task.company, subject: task)
      expect(notification.subject).to eq(task)
    end

    it "is nil when the subject was deleted" do
      task = create(:task)
      notification = create(:notification, company: task.company, subject: task)
      task.destroy!
      expect(notification.subject).to be_nil
    end
  end

  describe ".unread" do
    it "excludes read notifications" do
      unread = create(:notification)
      create(:notification, :read)
      expect(described_class.unread.to_a).to eq([unread])
    end
  end
end
