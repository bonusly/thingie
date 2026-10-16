FactoryBot.define do
  factory :audit_log do
    company
    actor_id { BSON::ObjectId.new }
    action { "list.created" }
    target_type { "List" }
    target_id { BSON::ObjectId.new }
    details { {} }
    ip { "203.0.113.7" }

    trait :suspension do
      action { "company.suspended" }
      target_type { "Company" }
      details { { "reason" => "billing" } }
    end
  end
end
