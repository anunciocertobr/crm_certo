class GoogleAdsAsset < ApplicationRecord
  KINDS = %w[audience keyword_group headline_set].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true, uniqueness: { scope: :kind }

  scope :by_kind, ->(kind) { where(kind: kind) }
  scope :alphabetical, -> { order(:name) }
end
