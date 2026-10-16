module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :company, index: true

    scope :for_company, ->(company) { where(company_id: company.id) }
    scope :for_companies, ->(companies) { self.in(company_id: companies.map(&:id)) }
  end

  def same_company?(other)
    other.respond_to?(:company_id) && other.company_id == company_id
  end

  def company_slug
    company&.slug
  end
end
