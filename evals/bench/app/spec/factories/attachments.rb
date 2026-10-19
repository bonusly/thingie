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

    trait :oversized do
      byte_size { Attachment::MAX_BYTES + 1 }
    end
  end
end
