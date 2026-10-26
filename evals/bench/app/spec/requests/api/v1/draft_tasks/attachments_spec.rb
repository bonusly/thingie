require "rails_helper"

RSpec.describe "Draft task attachments API" do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }
  let(:draft) { create(:draft_task, :with_recording, company: company, list: list, author: member) }
  let(:upload) { create(:attachment, :video, :unclaimed, company: company, uploader: member) }

  before { enable_feature(:draft_tasks) }

  def replace(user, attachment_id)
    api_patch "/api/v1/draft_tasks/#{draft.id}/attachment", user: user, company: company,
              params: { attachment_id: attachment_id }
  end

  it "swaps the recording for a fresh upload" do
    old_id = draft.attachment_id
    replace(member, upload.id.to_s)

    expect(response).to have_http_status(:ok)
    expect(json.dig("attachment", "id")).to eq(upload.id.to_s)
    expect(json.dig("attachment", "media_kind")).to eq("video")
    expect(Attachment.where(id: old_id)).not_to exist
  end

  it "rejects a non-media upload" do
    replace(member, create(:attachment, :unclaimed, company: company).id.to_s)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_error["message"]).to match(/audio or video/)
  end

  it "forbids non-authors" do
    replace(admin, upload.id.to_s)
    expect(response).to have_http_status(:forbidden)
  end

  it "refuses once the draft is ready" do
    draft.mark_ready!
    replace(member, upload.id.to_s)
    expect(response).to have_http_status(:forbidden)
  end
end
