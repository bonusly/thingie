FactoryBot.define do
  factory :points_ledger_entry do
    company
    user
    amount { 10 }
    kind { "award" }
    week_key { Points::Queries::WeeklyWindow.call(company: company).key }

    trait :refund do
      kind { "refund" }
    end

    trait :reset do
      kind { "reset" }
      amount { 100 }
      note { "weekly budget" }
    end

    trait :last_week do
      week_key { Points::Queries::WeeklyWindow.call(company: company, now: 1.week.ago).key }
    end
  end
end
