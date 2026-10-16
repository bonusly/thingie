module DraftTaskScoped
  extend ActiveSupport::Concern

  private

  def draft_tasks
    current_company.draft_tasks
  end
end
