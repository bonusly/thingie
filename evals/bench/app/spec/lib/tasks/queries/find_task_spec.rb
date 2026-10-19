require "rails_helper"

RSpec.describe Tasks::Queries::FindTask do
  let(:company) { create(:company) }
  let(:task) { create(:task, company: company) }

  it "finds a task in the company" do
    expect(described_class.call(company: company, id: task.id.to_s)).to eq(task)
  end

  it "raises NotFound for a task in another company" do
    expect { described_class.call(company: create(:company), id: task.id) }.to raise_error(Tasks::NotFound, /#{task.id}/)
  end

  it "raises NotFound for an unknown id" do
    expect { described_class.call(company: company, id: BSON::ObjectId.new) }.to raise_error(Tasks::NotFound)
  end
end
