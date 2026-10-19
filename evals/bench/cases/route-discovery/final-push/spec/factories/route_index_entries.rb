FactoryBot.define do
  factory :route_index_entry do
    sequence(:path) { |n| "/routes/#{n}" }
    sequence(:name) { |n| "routes.entry_#{n}" }
    component { "TasksPage" }
    indexed_at { 1.hour.ago }

    trait :gated do
      permission { "tasks:read" }
    end

    trait :staff_only do
      permission { "admin:staff" }
    end

    trait :flagged do
      flag { "points_ledger" }
    end

    trait :unreadable do
      unreadable { true }
    end

    trait :stale do
      indexed_at { 2.days.ago }
    end
  end
end
