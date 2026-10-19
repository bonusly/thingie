FactoryBot.define do
  factory :label do
    company
    sequence(:name) { |n| "label-#{n}" }
    color { "#ef4444" }

    trait :bug do
      name { "bug" }
      color { "#dc2626" }
    end

    trait :chore do
      name { "chore" }
      color { "#9ca3af" }
    end
  end
end
