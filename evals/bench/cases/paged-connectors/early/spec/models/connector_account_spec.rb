require "rails_helper"

RSpec.describe ConnectorAccount do
  let(:account) { create(:connector_account) }

  it "requires a supported provider" do
    expect(build(:connector_account, provider: "jira")).not_to be_valid
  end

  it "declares a unique index per company, provider and external account" do
    unique = described_class.index_specifications.select { |spec| spec.options[:unique] }
    expect(unique.map(&:key)).to include(company_id: 1, provider: 1, external_account_id: 1)
  end

  describe "access token" do
    it "round-trips through encryption" do
      account.access_token = "ghp_secret"
      expect(account.access_token_ciphertext).not_to include("ghp_secret")
      expect(account.access_token).to eq("ghp_secret")
    end
  end

  describe "state machine" do
    it "pauses, resumes and disconnects" do
      account.pause!
      expect(account).to be_paused
      account.resume!
      expect(account).to be_connected
      account.disconnect!
      expect(account.reload.access_token_ciphertext).to be_nil
      expect(account.cursor).to be_nil
    end
  end

  describe "#touch_synced!" do
    it "records the sync time and clears a previous error" do
      account.record_error!("boom")
      account.update!(cursor: "page-2")
      account.touch_synced!(synced_at: Time.utc(2026, 10, 16, 9))
      expect(account.reload.last_synced_at).to eq(Time.utc(2026, 10, 16, 9))
      expect(account.cursor).to be_nil
      expect(account.last_error).to be_nil
    end
  end
end
