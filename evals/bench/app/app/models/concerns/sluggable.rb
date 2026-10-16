module Sluggable
  extend ActiveSupport::Concern

  included do
    field :slug, type: String

    before_validation :assign_slug, on: :create
    validates :slug, presence: true, format: { with: /\A[a-z0-9-]+\z/ }
  end

  class_methods do
    def slug_source(attribute)
      @slug_source = attribute
    end

    def slug_source_attribute
      @slug_source || :name
    end
  end

  private

  def assign_slug
    return if slug.present?

    base = public_send(self.class.slug_source_attribute).to_s.parameterize
    self.slug = SlugGenerator.unique(base) { |candidate| slug_taken?(candidate) }
  end

  def slug_taken?(candidate)
    scope = self.class.where(slug: candidate)
    scope = scope.where(company_id: company_id) if respond_to?(:company_id)
    scope.exists?
  end
end
