FactoryBot.define do
  factory :api_key do
    company
    user
    label { "ci" }
    sequence(:prefix) { |n| format("key%05d", n) }
    token_digest { ApiKey.digest("#{prefix}-#{SecureRandom.hex(8)}") }

    trait :revoked do
      revoked_at { 1.day.ago }
    end

    trait :used do
      last_used_at { 1.minute.ago }
    end
  end
end
