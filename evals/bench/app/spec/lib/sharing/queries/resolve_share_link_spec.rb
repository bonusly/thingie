require "rails_helper"

RSpec.describe Sharing::Queries::ResolveShareLink do
  let(:link) { create(:share_link) }

  it "returns a live link" do
    expect(described_class.call(token: link.token)).to eq(link)
  end

  it "raises for unknown, expired or revoked tokens" do
    expect { described_class.call(token: "nope") }.to raise_error(Sharing::NotFound)
    expect { described_class.call(token: create(:share_link, :expired).token) }.to raise_error(Sharing::NotFound)
    expect { described_class.call(token: create(:share_link, :revoked).token) }.to raise_error(Sharing::NotFound)
  end

  it "raises when the list is archived or the company suspended" do
    link.list.archive!
    expect { described_class.call(token: link.token) }.to raise_error(Sharing::NotFound)

    other = create(:share_link)
    other.company.suspend!
    expect { described_class.call(token: other.token) }.to raise_error(Sharing::NotFound)
  end
end
