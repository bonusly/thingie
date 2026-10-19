module Tasks
  module Jobs
    class SendDueRemindersJob
      include Sidekiq::Job

      sidekiq_options queue: :notifications, retry: 3

      def perform(now_iso = nil)
        now = now_iso ? Time.iso8601(now_iso) : Time.current

        Reminder.due(now).each do |reminder|
          deliver(reminder)
        end
      end

      private

      def deliver(reminder)
        task = reminder.task
        return reminder.mark_sent! if task.nil? || task.archived?

        Notifications::Commands::Create.call(
          company: reminder.company, recipient: reminder.user, kind: "task_due_soon", subject: task,
          payload: { title: task.title, due_on: task.due_on&.iso8601 }
        )
        TaskMailer.reminder(reminder).deliver_now if reminder.channel == "email"
        reminder.mark_sent!
      end
    end
  end
end
