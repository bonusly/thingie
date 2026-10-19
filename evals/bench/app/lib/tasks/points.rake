namespace :points do
  desc "Reset weekly points budgets for every active company"
  task reset_weekly: :environment do
    Company.active.each do |company|
      result = Points::Commands::ResetWeeklyBudgets.call(company: company)
      puts "#{company.slug}: #{result.success? ? result.value[:reset] : result.error}"
    end
  end

  desc "Print giving balances for a company (COMPANY=slug)"
  task balances: :environment do
    company = Company.find_by!(slug: ENV.fetch("COMPANY"))
    company.memberships.active.each do |membership|
      balance = Points::Queries::GivingBalance.call(user: membership.user, company: company)
      puts format("%-30s %4d / %4d", membership.user.email, balance.remaining, balance.budget)
    end
  end
end
