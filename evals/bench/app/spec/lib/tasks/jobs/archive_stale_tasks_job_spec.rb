require "rails_helper"

RSpec.describe Tasks::Jobs::ArchiveStaleTasksJob do
  let(:company) { create(:company) }

  it "archives tasks done longer than the threshold" do
    stale = create(:task, :done, company: company, completed_at: 31.days.ago)
    recent = create(:task, :done, company: company, completed_at: 2.days.ago)
    open = create(:task, company: company)

    described_class.new.perform

    expect(stale.reload).to be_archived
    expect(recent.reload).to be_done
    expect(open.reload).to be_open
  end

  it "limits itself to one company when given an id" do
    other = create(:task, :done, completed_at: 40.days.ago)
    mine = create(:task, :done, company: company, completed_at: 40.days.ago)

    described_class.new.perform(company.id.to_s)

    expect(mine.reload).to be_archived
    expect(other.reload).to be_done
  end

  it "skips suspended companies" do
    task = create(:task, :done, company: create(:company, :suspended), completed_at: 40.days.ago)
    described_class.new.perform
    expect(task.reload).to be_done
  end
end
