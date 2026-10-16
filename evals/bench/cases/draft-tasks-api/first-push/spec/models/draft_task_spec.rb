require "rails_helper"

RSpec.describe DraftTask do
  let(:company) { create(:company) }
  let(:list) { create(:list, company: company) }
  let(:draft) { create(:draft_task, company: company, list: list, points: 10) }

  describe "state machine" do
    it "goes drafting -> ready -> sent" do
      draft.mark_ready!
      expect(draft.reload.ready_at).to be_present
      expect(draft.points_reserved_at).to eq(draft.ready_at)

      task = create(:task, company: company, list: list)
      draft.mark_sent!(task)
      expect(draft.reload).to be_sent
      expect(draft.sent_task).to eq(task)
    end

    it "returns to drafting from ready and clears the reservation" do
      draft.mark_ready!
      draft.resume_drafting!
      expect(draft.reload.ready_at).to be_nil
      expect(draft.points_reserved_at).to be_nil
      expect(draft).to be_editable
    end

    it "cannot be sent straight from drafting" do
      expect { draft.mark_sent!(create(:task, company: company, list: list)) }.to raise_error(DraftTasks::WrongState)
    end

    it "only claims the stored state, not the one in memory" do
      draft.mark_ready!
      stale = DraftTask.find(draft.id)
      draft.resume_drafting!

      expect { stale.mark_sent!(create(:task, company: company, list: list)) }.to raise_error(DraftTasks::WrongState)
      expect(draft.reload).to be_drafting
    end
  end

  describe "#reserved_points" do
    it "only counts points while the draft is ready" do
      expect(draft.reserved_points).to eq(0)
      draft.mark_ready!
      expect(draft.reserved_points).to eq(10)
    end
  end

  describe "#task_attributes" do
    it "copies the fields a task needs and points back at the draft" do
      draft = build(:draft_task, title: "Tag release", points: 5, due_on: Date.new(2026, 11, 1))
      expect(draft.task_attributes).to include(title: "Tag release", points: 5, due_on: Date.new(2026, 11, 1), draft_task_id: draft.id)
    end
  end

  describe "#attachment" do
    it "finds the recording by id" do
      recorded = create(:draft_task, :with_recording, company: company, list: list)
      expect(recorded.attachment).to be_audio
      expect(draft.attachment).to be_nil
    end
  end

  it "treats visibility private as private?" do
    expect(build(:draft_task, :private)).to be_private
    expect(build(:draft_task)).not_to be_private
  end
end
