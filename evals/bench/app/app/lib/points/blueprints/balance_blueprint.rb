module Points
  module Blueprints
    class BalanceBlueprint < Blueprinter::Base
      fields :budget, :spent, :reserved, :remaining, :week_key

      field :percent_remaining do |balance|
        balance.budget.zero? ? 0 : (balance.remaining * 100.0 / balance.budget).round
      end
      field :exhausted do |balance|
        balance.remaining.zero?
      end
      field :available do |balance|
        balance.budget - balance.spent
      end
    end
  end
end
