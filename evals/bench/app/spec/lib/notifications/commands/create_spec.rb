require "rails_helper"

RSpec.describe Notifications::Commands::Create do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: admin) }

  it "stores the subject and payload" do
    result = described_class.call(company: company, recipient: member, kind: "task_completed", subject: task, payload: { title: task.title })

    expect(result).to be_success
    expect(result.value).to have_attributes(subject_type: "Task", subject_id: task.id, payload: { "title" => task.title })
  end

  it "enqueues an email for emailed kinds only" do
    expect { described_class.call(company: company, recipient: member, kind: "task_assigned", subject: task) }
      .to change(Notifications::Jobs::DeliverNotificationJob.jobs, :size).by(1)
    expect { described_class.call(company: company, recipient: member, kind: "task_completed", subject: task) }
      .not_to change(Notifications::Jobs::DeliverNotificationJob.jobs, :size)
  end

  it "refuses non-members" do
    expect(described_class.call(company: company, recipient: outsider, kind: "task_assigned", subject: task)).to be_failure
  end

  it "rejects unknown kinds" do
    result = described_class.call(company: company, recipient: member, kind: "nudge", subject: task)
    expect(result).to be_failure
  end
end
