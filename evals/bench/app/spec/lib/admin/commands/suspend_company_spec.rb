require "rails_helper"

RSpec.describe Admin::Commands::SuspendCompany do
  include_context "with a company and members"

  let(:staff) { create(:user, :staff) }

  it "suspends the company, pauses connectors and revokes api keys" do
    account = create(:connector_account, company: company, user: member)
    key = create(:api_key, company: company, user: member)

    result = described_class.call(company: company, actor: staff, reason: "billing")

    expect(result).to be_success
    expect(company.reload).not_to be_active
    expect(account.reload).to be_paused
    expect(key.reload).not_to be_active
    expect(AuditLog.for_target(company).first.details).to eq("reason" => "billing")
  end

  it "requires staff" do
    expect(described_class.call(company: company, actor: admin, reason: "x").error).to be_a(Admin::NotStaff)
    expect(described_class.call(company: company, actor: nil, reason: "x").error).to be_a(Admin::NotStaff)
  end

  it "fails when already suspended" do
    company.suspend!
    expect(described_class.call(company: company, actor: staff, reason: "x").error).to be_a(Admin::AlreadySuspended)
  end
end
