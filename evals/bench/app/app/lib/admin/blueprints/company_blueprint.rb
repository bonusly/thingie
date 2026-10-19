module Admin
  module Blueprints
    class CompanyBlueprint < Blueprinter::Base
      identifier :id, &:to_s

      fields :name, :slug, :plan, :weekly_points_budget, :week_starts_on, :time_zone, :suspended_at, :created_at

      field :active, &:active?

      view :with_stats do
        field :stats do |company|
          Admin::Queries::CompanyStats.call(company: company).to_h.except(:company)
        end
      end
    end
  end
end
