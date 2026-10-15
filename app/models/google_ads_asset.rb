class GoogleAdsAsset < ApplicationRecord
  KINDS = %w[audience keyword_group headline_set sitelink callout structured_snippet call lead_form price
             image_asset].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true, uniqueness: { scope: :kind }

  scope :by_kind, ->(kind) { where(kind: kind) }
  scope :alphabetical, -> { order(:name) }
end
