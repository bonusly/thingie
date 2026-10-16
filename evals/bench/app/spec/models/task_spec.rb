require "rails_helper"

RSpec.describe Task do
  let(:company) { create(:company) }
  let(:list) { create(:list, company: company) }

  describe "validations" do
    it "caps points at MAX_POINTS" do
      expect(build(:task, company: company, list: list, points: Task::MAX_POINTS + 1)).not_to be_valid
    end

    it "rejects a list from another company" do
      task = build(:task, company: company, list: create(:list))
      expect(task).not_to be_valid
      expect(task.errors[:list]).to be_present
    end
  end

  describe "state machine" do
    let(:task) { create(:task, company: company, list: list) }

    it "records completed_at on complete and clears it on reopen" do
      task.complete!
      expect(task.reload.completed_at).to be_present
      task.reopen!
      expect(task.reload.completed_at).to be_nil
    end

    it "archives from open or done but never back" do
      task.archive!
      expect(task).to be_archived
      expect(task.may_reopen?).to be(false)
    end
  end

  describe "#overdue?" do
    it "is true only for open tasks with a past due date" do
      today = Date.new(2026, 10, 16)
      expect(build(:task, due_on: today - 1).overdue?(today: today)).to be(true)
      expect(build(:task, due_on: today).overdue?(today: today)).to be(false)
      expect(build(:task, :done, due_on: today - 1).overdue?(today: today)).to be(false)
    end
  end

  describe ".assigned_to" do
    it "matches tasks listing the user as an assignee" do
      user = create(:user)
      mine = create(:task, company: company, list: list, assignee_ids: [user.id])
      create(:task, company: company, list: list)
      expect(described_class.assigned_to(user).to_a).to eq([mine])
    end
  end
end
