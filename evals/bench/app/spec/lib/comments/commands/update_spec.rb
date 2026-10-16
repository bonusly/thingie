require "rails_helper"

RSpec.describe Comments::Commands::Update do
  include_context "with a company and members"

  let(:comment) { create(:comment, company: company, author: member, body: "first") }

  it "changes the body and marks it edited" do
    result = described_class.call(comment: comment, actor: member, body: "second")
    expect(result).to be_success
    expect(comment.reload.body).to eq("second")
    expect(comment).to be_edited
  end

  it "does not mark unchanged comments as edited" do
    described_class.call(comment: comment, actor: member, body: "first")
    expect(comment.reload).not_to be_edited
  end

  it "refuses non-authors, including admins" do
    result = described_class.call(comment: comment, actor: admin, body: "second")
    expect(result.error).to be_a(Comments::NotAuthor)
  end
end
