module Sharing
  module Blueprints
    class PublicListBlueprint < Blueprinter::Base
      field :name do |view|
        view.list.name
      end
      field :description do |view|
        view.list.description
      end
      field :tasks do |view|
        Tasks::Blueprints::TaskSummaryBlueprint.render_as_hash(view.tasks)
      end
      field :drafts do |view|
        Sharing::Blueprints::PublicDraftBlueprint.render_as_hash(view.drafts)
      end
      field :expires_at do |view|
        view.share_link.expires_at
      end
    end
  end
end
