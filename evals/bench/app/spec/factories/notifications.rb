FactoryBot.define do
  factory :notification do
    transient do
      subject { association :task, company: company }
    end

    company
    recipient { association :user }
    kind { "task_assigned" }
    subject_type { subject.class.name }
    subject_id { subject.id }
    payload { { "title" => "Write the release notes" } }

    trait :read do
      read_at { 1.minute.ago }
    end

    trait :mention do
      kind { "mentioned" }
      payload { { "excerpt" => "@ada can you look?", "by" => "Grace" } }
    end

    trait :stale do
      created_at { 3.days.ago }
    end
  end
end
