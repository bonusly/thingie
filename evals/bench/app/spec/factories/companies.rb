FactoryBot.define do
  factory :company do
    sequence(:name) { |n| "Company #{n}" }
    sequence(:slug) { |n| "company-#{n}" }
    plan { "team" }
    weekly_points_budget { 100 }
    week_starts_on { 1 }
    time_zone { "UTC" }

    trait :suspended do
      suspended_at { 1.day.ago }
    end

    trait :free do
      plan { "free" }
      weekly_points_budget { 20 }
    end

    trait :denver do
      time_zone { "America/Denver" }
      week_starts_on { 0 }
    end
  end
end
