require "rails_helper"

RSpec.describe DraftTask do
  let(:company) { create(:company) }
  let(:list) { create(:list, company: company) }
  let(:draft) { create(:draft_task, company: company, list: list, points: 10) }

  describe "state machine" do
    it "goes drafting -> ready -> sent" do
      draft.mark_ready!
      expect(draft.reload.ready_at).to be_present

      task = create(:task, company: company, list: list)
      draft.mark_sent!(task)
      expect(draft.reload).to be_sent
      expect(draft.sent_task).to eq(task)
    end

    it "returns to drafting from ready and clears ready_at" do
      draft.mark_ready!
      draft.resume_drafting!
      expect(draft.reload.ready_at).to be_nil
      expect(draft).to be_editable
    end

    it "cannot be sent straight from drafting" do
      expect { draft.mark_sent!(create(:task, company: company, list: list)) }.to raise_error(AASM::InvalidTransition)
    end
  end

  describe "#release_reservation!" do
    it "moves a ready draft back to drafting" do
      draft.mark_ready!
      draft.release_reservation!
      expect(draft.reload).to be_drafting
      expect(draft.ready_at).to be_nil
    end

    it "leaves a draft alone once another process has sent it" do
      draft.mark_ready!
      stale = described_class.find(draft.id)
      draft.mark_sent!(create(:task, company: company, list: list))

      expect { stale.release_reservation! }.to raise_error(DraftTasks::WrongState)
      expect(draft.reload).to be_sent
    end
  end

  describe "#reserved_points" do
    it "only counts points while the draft is ready" do
      expect(draft.reserved_points).to eq(0)
      draft.mark_ready!
      expect(draft.reserved_points).to eq(10)
    end
  end

  describe "points_within_budget" do
    let(:author) { create(:user) }

    before { create(:membership, company: company, user: author, points_budget_override: 20) }

    it "rejects points above the author's weekly budget" do
      over = build(:draft_task, company: company, list: list, author: author, points: 25)
      expect(over).not_to be_valid
      expect(over.errors[:points].first).to match(/weekly budget of 20/)
    end

    it "accepts points up to the budget" do
      expect(build(:draft_task, company: company, list: list, author: author, points: 20)).to be_valid
    end
  end

  describe ".reserving" do
    it "lists ready drafts that hold points" do
      held = create(:draft_task, :ready, company: company, list: list, points: 5)
      create(:draft_task, :ready, company: company, list: list, points: 0)
      create(:draft_task, company: company, list: list, points: 5)
      expect(described_class.reserving.to_a).to eq([held])
    end
  end

  describe "#task_attributes" do
    it "copies the fields a task needs" do
      draft = build(:draft_task, title: "Tag release", points: 5, due_on: Date.new(2026, 11, 1))
      expect(draft.task_attributes).to include(title: "Tag release", points: 5, due_on: Date.new(2026, 11, 1))
    end
  end

  it "treats visibility private as private?" do
    expect(build(:draft_task, :private)).to be_private
    expect(build(:draft_task)).not_to be_private
  end
end
