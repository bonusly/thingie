require "rails_helper"

RSpec.describe DraftTasks::Commands::ReplaceAttachment do
  include_context "with a company and members"

  let(:list) { create(:list, company: company, owner: admin, member_ids: [admin.id, member.id]) }
  let(:draft) { create(:draft_task, :with_recording, company: company, list: list, author: member) }
  let(:upload) { create(:attachment, :audio, :unclaimed, company: company, uploader: member) }

  def replace(attachment, actor: member)
    described_class.call(draft: draft, actor: actor, attachment_id: attachment.id)
  end

  it "claims the new upload and removes the old recording" do
    old_id = draft.attachment_id

    expect(replace(upload)).to be_success
    expect(draft.reload.attachment_id).to eq(upload.id)
    expect(upload.reload.draft_task_id).to eq(draft.id)
    expect(Attachment.where(id: old_id)).not_to exist
  end

  it "refuses uploads that are not audio or video" do
    result = replace(create(:attachment, :image, :unclaimed, company: company))
    expect(result.error.message).to match(/audio or video/)
  end

  it "refuses uploads already attached elsewhere" do
    result = replace(create(:attachment, :video, company: company))
    expect(result.error.message).to match(/already attached/)
  end

  it "rejects a recording over the media limit" do
    result = replace(create(:attachment, :audio, :unclaimed, :oversized_media, company: company))
    expect(result).to be_failure
    expect(result.error).to include(a_string_matching(/Byte size/))
  end

  it "refuses non-authors and ready drafts" do
    expect(replace(upload, actor: admin)).to be_failure
    draft.mark_ready!
    expect(replace(upload).error).to be_a(DraftTasks::NotEditable)
  end
end
