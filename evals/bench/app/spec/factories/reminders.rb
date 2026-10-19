FactoryBot.define do
  factory :reminder do
    company
    task { association :task, company: company }
    user
    remind_at { 1.hour.from_now }
    channel { "in_app" }

    trait :email do
      channel { "email" }
    end

    trait :sent do
      sent_at { 5.minutes.ago }
    end
  end
end
