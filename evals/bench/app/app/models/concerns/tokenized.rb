module Tokenized
  extend ActiveSupport::Concern

  included do
    field :token, type: String

    index({ token: 1 }, { unique: true, sparse: true })

    before_validation :assign_token, on: :create
    validates :token, presence: true, uniqueness: true
  end

  class_methods do
    def token_length(length = nil)
      @token_length = length if length
      @token_length || 24
    end
  end

  private

  def assign_token
    self.token ||= TokenGenerator.urlsafe(self.class.token_length)
  end
end
