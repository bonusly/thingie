FactoryBot.define do
  factory :share_link do
    company
    list { association :list, company: company }
    created_by { association :user }
    expires_at { 7.days.from_now }
    show_drafts { false }

    trait :with_drafts do
      show_drafts { true }
    end

    trait :expired do
      expires_at { 1.hour.ago }
    end

    trait :revoked do
      revoked_at { 1.hour.ago }
    end
  end
end
