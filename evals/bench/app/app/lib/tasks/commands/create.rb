module Tasks
  module Commands
    class Create
      PERMITTED = %i[title description due_on points assignee_ids label_ids position external_item_id].freeze

      def self.call(**)
        new(**).call
      end

      def initialize(company:, author:, list:, attrs:)
        @company = company
        @author = author
        @list = list
        @attrs = attrs.to_h.symbolize_keys.slice(*PERMITTED)
      end

      def call
        return Result.failure(Tasks::WrongCompany.new) unless list.company_id == company.id

        task = Task.new(attrs.merge(company: company, author: author, list: list))
        return Result.failure(task.errors.full_messages) unless task.valid?

        shortfall = balance_shortfall(task)
        return Result.failure(shortfall) if shortfall

        task.save!
        award_points(task)
        TaskEvent.track!(task: task, actor: author, kind: "created")
        notify_assignees(task)
        WebhookDispatcher.dispatch(company: company, event: "task.created", payload: { task_id: task.id.to_s })
        Result.success(task)
      end

      private

      attr_reader :company, :author, :list, :attrs

      def balance_shortfall(task)
        return nil unless task.rewarded?

        balance = Points::Queries::GivingBalance.call(user: author, company: company)
        return nil if balance.covers?(task.points)

        Points::InsufficientBalance.new(requested: task.points, remaining: balance.remaining)
      rescue Points::NotAMember => e
        e
      end

      def award_points(task)
        return unless task.rewarded?

        Points::Commands::Award.call(company: company, user: author, task: task, amount: task.points).value!
      end

      def notify_assignees(task)
        task.assignees.each do |assignee|
          next if assignee.id == author.id

          Notifications::Commands::Create.call(
            company: company, recipient: assignee, kind: "task_assigned", subject: task,
            payload: { title: task.title, assigned_by: author.display_name }
          )
        end
      end
    end
  end
end
