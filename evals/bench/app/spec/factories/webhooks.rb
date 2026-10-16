FactoryBot.define do
  factory :webhook do
    company
    sequence(:url) { |n| "https://hooks.example.test/#{n}" }
    events { %w[task.created task.completed] }
    active { true }

    trait :inactive do
      active { false }
    end

    trait :flaky do
      failure_count { Webhook::DISABLE_AFTER - 1 }
    end

    trait :all_events do
      events { Webhook::EVENTS }
    end
  end
end
