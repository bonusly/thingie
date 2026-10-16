require "rails_helper"

RSpec.describe ShareLink do
  it "generates a long unique token" do
    link = create(:share_link)
    expect(link.token.length).to eq(32)
    expect(build(:share_link, token: link.token)).not_to be_valid
  end

  describe ".find_active" do
    it "finds by token while the link is live" do
      link = create(:share_link)
      expect(described_class.find_active(link.token)).to eq(link)
    end

    it "ignores expired and revoked links" do
      expired = create(:share_link, :expired)
      revoked = create(:share_link, :revoked)
      expect(described_class.find_active(expired.token)).to be_nil
      expect(described_class.find_active(revoked.token)).to be_nil
    end
  end

  describe "#record_view!" do
    it "counts views" do
      link = create(:share_link)
      2.times { link.record_view! }
      expect(link.reload.view_count).to eq(2)
    end
  end

  it "becomes inactive after revoke!" do
    link = create(:share_link)
    link.revoke!
    expect(link).not_to be_active
  end
end
