require "rails_helper"

RSpec.describe Points::Commands::SettleReservation do
  include_context "with a list and a ready draft"

  let(:task) { create(:task, company: company, list: list, author: member, points: 10) }

  it "writes an award entry tied to the draft and the task" do
    result = described_class.call(draft: draft, task: task, amount: 10)

    expect(result).to be_success
    expect(result.value).to have_attributes(
      amount: 10, kind: "award", task_id: task.id, draft_task_id: draft.id, note: PointsLedgerEntry::ESCROW_NOTE
    )
    expect(task.events.of_kind("points_awarded").count).to eq(1)
  end

  it "uses the week the draft is settled in" do
    travel_to(Time.utc(2026, 10, 14, 12)) do
      entry = described_class.call(draft: draft, task: task, amount: 10).value
      expect(entry.week_key).to eq("2026-W42")
    end
  end

  it "writes nothing for zero points" do
    result = described_class.call(draft: draft, task: task, amount: 0)
    expect(result).to be_success
    expect(PointsLedgerEntry.for_draft(draft)).not_to exist
  end

  it "refuses a draft that is not ready" do
    drafting = create(:draft_task, company: company, list: list, author: member, points: 10)
    expect(described_class.call(draft: drafting, task: task, amount: 10).error).to be_a(DraftTasks::WrongState)
  end

  it "logs and re-raises when the ledger write fails" do
    allow(PointsLedgerEntry).to receive(:create!).and_raise(Mongo::Error::OperationFailure, "down")
    allow(Rails.logger).to receive(:error)

    expect { described_class.call(draft: draft, task: task, amount: 10) }.to raise_error(Mongo::Error::OperationFailure)
    expect(Rails.logger).to have_received(:error).with(/escrow settle failed for draft #{draft.id}/)
  end
end
