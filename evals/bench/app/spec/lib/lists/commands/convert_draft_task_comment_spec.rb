require "rails_helper"

RSpec.describe Lists::Commands::ConvertDraftTaskComment do
  include_context "with a list and a ready draft"

  it "sends the draft and attaches its note as a comment" do
    result = described_class.call(draft: draft, actor: admin)

    expect(result).to be_success
    task = result.value[:task]
    comment = result.value[:comment]
    expect(task.list).to eq(list)
    expect(comment.commentable).to eq(task)
    expect(comment.body).to eq("ship it")
    expect(comment.author).to eq(member)
    expect(comment.draft_task_id).to eq(draft.id)
    expect(draft.reload).to be_sent
    expect(draft.sent_task_id).to eq(task.id)
  end

  it "tells the author which comment carried the note" do
    result = described_class.call(draft: draft, actor: admin)
    notification = Notification.for_recipient(member).where(kind: "draft_sent").first
    expect(notification.payload["comment_id"]).to eq(result.value[:comment].id.to_s)
  end

  it "skips the comment when the draft has no note" do
    draft.update!(note: nil)
    result = described_class.call(draft: draft, actor: admin)
    expect(result.value[:comment]).to be_nil
    expect(result.value[:task].comments.count).to eq(0)
  end

  it "fails for a draft that is not ready" do
    drafting = create(:draft_task, company: company, list: list, author: member)
    expect(described_class.call(draft: drafting, actor: admin).error).to be_a(DraftTasks::WrongState)
  end
end
