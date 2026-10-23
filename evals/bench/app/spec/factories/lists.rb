FactoryBot.define do
  factory :list do
    company
    owner { association :user }
    sequence(:name) { |n| "List #{n}" }
    visibility { "company" }
    member_ids { [owner.id] }

    trait :private do
      visibility { "private" }
    end

    trait :public do
      visibility { "public" }
    end

    trait :archived do
      state { "archived" }
    end

    trait :deleted do
      deleted_at { 1.hour.ago }
    end

    trait :delivered do
      delivered_at { 1.hour.ago }
    end
  end
end
