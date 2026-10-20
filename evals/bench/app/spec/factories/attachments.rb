FactoryBot.define do
  factory :attachment do
    company
    task { association :task, company: company }
    uploader { association :user }
    filename { "notes.pdf" }
    content_type { "application/pdf" }
    byte_size { 42_000 }
    sequence(:storage_key) { |n| "uploads/#{n}/notes.pdf" }
    checksum { Digest::MD5.hexdigest(storage_key) }

    trait :image do
      filename { "screenshot.png" }
      content_type { "image/png" }
    end

    trait :audio do
      filename { "voice-note.mp3" }
      content_type { "audio/mpeg" }
      byte_size { 1_200_000 }
    end

    trait :video do
      filename { "walkthrough.mp4" }
      content_type { "video/mp4" }
      byte_size { 8_000_000 }
    end

    trait :unclaimed do
      task { nil }
    end

    trait :oversized do
      byte_size { Attachment::MAX_BYTES + 1 }
    end

    trait :oversized_media do
      byte_size { Attachment::MEDIA_MAX_BYTES + 1 }
    end
  end
end
