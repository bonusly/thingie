class TaskMailer < ApplicationMailer
  def reminder(reminder)
    @reminder = reminder
    @task = reminder.task
    @user = reminder.user
    @task_url = app_url("/tasks/#{@task.id}")

    with_user_locale(@user) do
      mail(to: @user.email, subject: t("mailers.task.reminder.subject", title: @task.title), reply_to: reply_to_for(@task))
    end
  end

  private

  def reply_to_for(task)
    task.author.email
  end
end
