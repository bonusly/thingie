require "rails_helper"

RSpec.describe AuditLog do
  describe ".record!" do
    let(:company) { create(:company) }
    let(:actor) { create(:user) }
    let(:list) { create(:list, company: company) }

    it "captures the actor, target and details" do
      log = described_class.record!(company: company, actor: actor, action: "list.created", target: list, details: { fields: ["name"] })

      expect(log.actor).to eq(actor)
      expect(log.target_type).to eq("List")
      expect(log.target_id).to eq(list.id)
      expect(log.details).to eq("fields" => ["name"])
    end

    it "allows a nil actor for system actions" do
      log = described_class.record!(company: company, actor: nil, action: "list.archived", target: list)
      expect(log.actor).to be_nil
    end
  end

  describe ".for_target" do
    it "filters by the target record" do
      list = create(:list)
      matching = create(:audit_log, company: list.company, target_type: "List", target_id: list.id)
      create(:audit_log, company: list.company)
      expect(described_class.for_target(list).to_a).to eq([matching])
    end
  end
end
