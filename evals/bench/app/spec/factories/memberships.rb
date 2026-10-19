FactoryBot.define do
  factory :membership do
    company
    user
    role { "member" }
    state { "active" }
    joined_at { 1.week.ago }

    trait :admin do
      role { "admin" }
    end

    trait :removed do
      state { "removed" }
      removed_at { 1.day.ago }
    end

    trait :with_budget_override do
      points_budget_override { 40 }
    end
  end
end
