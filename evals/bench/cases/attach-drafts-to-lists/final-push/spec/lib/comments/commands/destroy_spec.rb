require "rails_helper"

RSpec.describe Comments::Commands::Destroy do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin) }

  it "removes a plain comment for its author" do
    comment = create(:comment, company: company, commentable: list, author: member)
    expect(described_class.call(comment: comment, actor: member)).to be_success
    expect(Comment.where(id: comment.id)).not_to exist
  end

  it "releases the draft when the comment is the one that attached it" do
    draft = create(:draft_task, company: company, author: member, points: 10)
    DraftTasks::Commands::Attach.call(draft: draft, list: list, actor: member)
    comment = list.comments.from_drafts.first

    result = described_class.call(comment: comment, actor: member)

    expect(result).to be_success
    expect(Comment.where(id: comment.id)).not_to exist
    expect(draft.reload).to be_drafting
    expect(draft.list).to be_nil
    expect(Points::Queries::GivingBalance.call(user: member, company: company).reserved).to eq(0)
  end

  it "just removes the comment when its draft is gone" do
    comment = create(:comment, company: company, commentable: list, author: member, draft_task_id: BSON::ObjectId.new)
    expect(described_class.call(comment: comment, actor: member)).to be_success
    expect(Comment.where(id: comment.id)).not_to exist
  end

  it "lets an admin remove someone else's comment and refuses other members" do
    comment = create(:comment, company: company, commentable: list, author: member)
    expect(described_class.call(comment: comment, actor: outsider).error).to be_a(Comments::NotAuthor)
    expect(described_class.call(comment: comment, actor: admin)).to be_success
  end
end
