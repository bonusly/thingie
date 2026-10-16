require "rails_helper"

RSpec.describe Lists::Commands::Create do
  include_context "with a company and members"

  it "creates the list with the owner as a member and logs it" do
    result = described_class.call(company: company, owner: admin, attrs: { name: "Launch", member_ids: [member.id] })

    expect(result).to be_success
    list = result.value
    expect(list.member_ids).to match_array([member.id, admin.id])
    expect(list.slug).to eq("launch")
    expect(AuditLog.for_target(list).where(action: "list.created").count).to eq(1)
  end

  it "ignores state and company overrides" do
    result = described_class.call(company: company, owner: admin, attrs: { name: "x", state: "archived", company_id: create(:company).id })
    expect(result.value).to be_active
    expect(result.value.company).to eq(company)
  end

  it "fails without a name" do
    result = described_class.call(company: company, owner: admin, attrs: { name: "" })
    expect(result).to be_failure
    expect(result.error).to include(a_string_matching(/Name/))
  end
end
