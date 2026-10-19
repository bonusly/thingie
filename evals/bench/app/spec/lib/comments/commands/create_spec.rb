require "rails_helper"

RSpec.describe Comments::Commands::Create do
  include_context "with a company and members"

  let(:task) { create(:task, company: company, author: admin) }

  it "creates the comment, tracks a task event and dispatches a webhook" do
    create(:webhook, company: company, events: %w[comment.created])

    result = described_class.call(company: company, author: member, commentable: task, attrs: { body: "Looks good" })

    expect(result).to be_success
    expect(result.value.commentable).to eq(task)
    expect(task.events.of_kind("commented").count).to eq(1)
    expect(WebhookDelivery.where(event: "comment.created").count).to eq(1)
  end

  it "resolves mentions and notifies them" do
    ada = create(:user, email: "ada@example.test")
    create(:membership, company: company, user: ada)

    result = described_class.call(company: company, author: member, commentable: task, attrs: { body: "@ada can you check?" })

    expect(result.value.mentioned_user_ids).to eq([ada.id])
    expect(Notification.for_recipient(ada).where(kind: "mentioned").count).to eq(1)
  end

  it "works on lists without task side effects" do
    list = create(:list, company: company, owner: admin)
    result = described_class.call(company: company, author: member, commentable: list, attrs: { body: "Kickoff notes" })
    expect(result.value.commentable).to eq(list)
    expect(TaskEvent.count).to eq(0)
  end

  it "refuses cross-company comments" do
    result = described_class.call(company: create(:company), author: member, commentable: task, attrs: { body: "x" })
    expect(result).to be_failure
  end
end
