require "rails_helper"

RSpec.describe Comment do
  it "requires a body under the maximum length" do
    expect(build(:comment, body: "")).not_to be_valid
    expect(build(:comment, body: "x" * (Comment::MAX_BODY + 1))).not_to be_valid
  end

  it "can belong to a list as well as a task" do
    comment = create(:comment, :on_list)
    expect(comment.commentable).to be_a(List)
  end

  describe "#mentions" do
    it "resolves mentioned users" do
      users = create_list(:user, 2)
      comment = create(:comment, mentioned_user_ids: users.map(&:id))
      expect(comment.mentions.to_a).to match_array(users)
    end
  end

  describe "#editable_by?" do
    it "is true only for the author" do
      comment = create(:comment)
      expect(comment.editable_by?(comment.author)).to be(true)
      expect(comment.editable_by?(create(:user))).to be(false)
    end
  end

  it "knows when it came from a draft" do
    expect(build(:comment, :from_draft)).to be_from_draft
    expect(build(:comment)).not_to be_from_draft
  end
end
