FactoryBot.define do
  factory :external_item do
    company
    connector_account { association :connector_account, company: company }
    provider { connector_account.provider }
    sequence(:external_id) { |n| "ext-#{n}" }
    kind { "issue" }
    sequence(:title) { |n| "Fix flaky build ##{n}" }
    url { "https://github.com/acme/app/issues/#{external_id}" }
    external_updated_at { 1.hour.ago }

    trait :pull_request do
      kind { "pull_request" }
    end

    trait :imported do
      imported_task_id { BSON::ObjectId.new }
    end
  end
end
