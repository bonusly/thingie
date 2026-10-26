FactoryBot.define do
  factory :connector_account do
    company
    user
    provider { "github" }
    sequence(:external_account_id) { |n| "acct-#{n}" }
    external_account_name { "octocat" }
    access_token { "token-#{SecureRandom.hex(4)}" }

    trait :slack do
      provider { "slack" }
      external_account_name { "T0123" }
    end

    trait :linear do
      provider { "linear" }
      external_account_name { "ACME" }
    end

    trait :with_channels do
      settings { { "channels" => %w[C123 C456] } }
    end

    trait :paused do
      state { "paused" }
    end

    trait :synced do
      last_synced_at { 1.hour.ago }
    end
  end
end
