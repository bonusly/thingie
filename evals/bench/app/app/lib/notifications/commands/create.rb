module Notifications
  module Commands
    class Create
      EMAILED_KINDS = %w[task_assigned mentioned invitation].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(company:, recipient:, kind:, subject:, payload: {})
        @company = company
        @recipient = recipient
        @kind = kind
        @subject = subject
        @payload = payload
      end

      def call
        return Result.failure("recipient is not a member") unless recipient.member_of?(company)

        notification = Notification.new(
          company: company, recipient: recipient, kind: kind,
          subject_type: subject.class.name, subject_id: subject.id, payload: payload.stringify_keys
        )
        return Result.failure(notification.errors.full_messages) unless notification.save

        Notifications::Jobs::DeliverNotificationJob.perform_async(notification.id.to_s) if EMAILED_KINDS.include?(kind)
        Result.success(notification)
      end

      private

      attr_reader :company, :recipient, :kind, :subject, :payload
    end
  end
end
