FactoryBot.define do
  factory :webhook_delivery do
    webhook
    event { "task.created" }
    payload { { "task_id" => BSON::ObjectId.new.to_s } }

    trait :delivered do
      state { "delivered" }
      response_status { 200 }
      delivered_at { 1.minute.ago }
      attempts { 1 }
    end

    trait :exhausted do
      attempts { WebhookDelivery::MAX_ATTEMPTS }
    end
  end
end
