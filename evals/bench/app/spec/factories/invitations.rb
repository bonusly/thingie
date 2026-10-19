FactoryBot.define do
  factory :invitation do
    company
    invited_by { association :user }
    sequence(:email) { |n| "invitee#{n}@example.test" }
    role { "member" }
    expires_at { 7.days.from_now }

    trait :admin do
      role { "admin" }
    end

    trait :accepted do
      accepted_at { 1.day.ago }
    end

    trait :expired do
      expires_at { 1.day.ago }
    end
  end
end
