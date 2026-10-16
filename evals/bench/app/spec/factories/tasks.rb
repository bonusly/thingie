FactoryBot.define do
  factory :task do
    company
    list { association :list, company: company }
    author { association :user }
    sequence(:title) { |n| "Task #{n}" }
    points { 0 }

    trait :done do
      state { "done" }
      completed_at { 1.hour.ago }
    end

    trait :archived do
      state { "archived" }
      archived_at { 1.hour.ago }
    end

    trait :overdue do
      due_on { 2.days.ago.to_date }
    end

    trait :due_soon do
      due_on { 1.day.from_now.to_date }
    end

    trait :rewarded do
      points { 10 }
    end
  end
end
