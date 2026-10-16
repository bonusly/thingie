FactoryBot.define do
  factory :task_event do
    company
    task { association :task, company: company }
    actor_id { BSON::ObjectId.new }
    kind { "created" }
    data { {} }

    trait :completed do
      kind { "completed" }
    end

    trait :assigned do
      kind { "assigned" }
      data { { "user_ids" => [BSON::ObjectId.new.to_s] } }
    end
  end
end
