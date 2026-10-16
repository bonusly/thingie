FactoryBot.define do
  factory :team do
    company
    sequence(:name) { |n| "Team #{n}" }
    member_ids { [] }

    trait :with_lead do
      lead_id { BSON::ObjectId.new }
    end

    trait :with_members do
      member_ids { [BSON::ObjectId.new, BSON::ObjectId.new] }
    end
  end
end
