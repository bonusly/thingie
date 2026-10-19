require "rails_helper"

RSpec.describe ApiKey do
  let(:company) { create(:company) }
  let(:user) { create(:user) }

  describe ".generate" do
    it "returns the key and the raw token, storing only a digest" do
      key, raw = described_class.generate(company: company, user: user, label: "ci")
      expect(raw).to be_present
      expect(key.token_digest).to eq(described_class.digest(raw))
      expect(key.prefix).to eq(raw[0, ApiKey::PREFIX_LENGTH])
    end
  end

  describe ".authenticate" do
    it "finds an active key by raw token" do
      key, raw = described_class.generate(company: company, user: user)
      expect(described_class.authenticate(raw)).to eq(key)
    end

    it "ignores revoked keys and blank tokens" do
      key, raw = described_class.generate(company: company, user: user)
      key.revoke!
      expect(described_class.authenticate(raw)).to be_nil
      expect(described_class.authenticate("")).to be_nil
    end
  end

  describe "#touch_used!" do
    it "records the last use" do
      key = create(:api_key, company: company, user: user)
      key.touch_used!
      expect(key.reload.last_used_at).to be_present
    end
  end
end
