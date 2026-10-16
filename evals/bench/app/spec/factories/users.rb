FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.test" }
    sequence(:name) { |n| "User #{n}" }
    password { "correct horse battery" }
    time_zone { "UTC" }
    locale { "en" }

    trait :staff do
      staff { true }
    end

    trait :recently_seen do
      last_seen_at { 10.minutes.ago }
    end
  end
end
