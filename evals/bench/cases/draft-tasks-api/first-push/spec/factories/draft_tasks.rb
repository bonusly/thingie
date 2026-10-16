FactoryBot.define do
  factory :draft_task do
    company
    list { association :list, company: company }
    author { association :user }
    sequence(:title) { |n| "Draft #{n}" }
    points { 0 }
    visibility { "shared" }

    trait :ready do
      state { "ready" }
      ready_at { 5.minutes.ago }
      points_reserved_at { 5.minutes.ago }
    end

    trait :sent do
      state { "sent" }
      ready_at { 1.hour.ago }
      points_reserved_at { 1.hour.ago }
      sent_at { 30.minutes.ago }
    end

    trait :private do
      visibility { "private" }
    end

    trait :scheduled do
      scheduled_for { 1.hour.from_now }
    end

    trait :with_points do
      points { 15 }
    end

    trait :with_recording do
      after(:create) do |draft|
        recording = create(:attachment, :audio, :unclaimed, company: draft.company, uploader: draft.author,
                                                            draft_task_id: draft.id)
        draft.set(attachment_id: recording.id)
      end
    end
  end
end
