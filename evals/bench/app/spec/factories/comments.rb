FactoryBot.define do
  factory :comment do
    company
    commentable { association :task, company: company }
    author { association :user }
    sequence(:body) { |n| "Comment number #{n}" }

    trait :on_list do
      commentable { association :list, company: company }
    end

    trait :edited do
      edited_at { 10.minutes.ago }
    end

    trait :from_draft do
      draft_task_id { BSON::ObjectId.new }
    end
  end
end
