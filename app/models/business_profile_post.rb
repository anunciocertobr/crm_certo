# == Schema Information
#
# Table name: business_profile_posts
#
#  id                 :uuid             not null, primary key
#  account_name       :string           not null
#  created_by         :uuid             not null
#  cta_action_type    :string
#  cta_url            :string
#  error_message      :text
#  external_post_name :string
#  location_title     :string
#  status             :string           default("pending"), not null
#  summary            :text             not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  location_id        :string           not null
#
# Indexes
#
#  index_business_profile_posts_on_created_by  (created_by)
#  index_business_profile_posts_on_status      (status)
#
# Um post ("Local Post") do "Gestor de Posts" publicado numa localização do
# Google Meu Negócio (Business Profile) — mesma conexão Google Workspace já
# usada pra GTM/GA4/YouTube (escopo business.manage). Local Posts não têm
# Channel próprio (a localização é só um nome de recurso do Google, sem
# registro no banco), por isso este modelo segue o mesmo padrão de
# YoutubeUpload em vez do de GestorPosts::Upload — ver
# GestorPosts::BusinessProfilePublishJob e Google::BusinessProfileService.
class BusinessProfilePost < ApplicationRecord
  self.table_name = 'business_profile_posts'

  has_one_attached :media
  belongs_to :creator, class_name: 'User', foreign_key: :created_by, inverse_of: false

  STATUSES = %w[pending publishing published failed].freeze

  validates :account_name, presence: true
  validates :location_id, presence: true
  validates :summary, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  def public_media_url
    return nil unless media.attached?

    BlobUrlOptions.outbound_media_url(media.blob)
  end

  def mark_publishing!
    update!(status: 'publishing')
  end

  def mark_published!(post_name)
    update!(status: 'published', external_post_name: post_name, error_message: nil)
  end

  def mark_failed!(error)
    update!(status: 'failed', error_message: error.to_s)
  end
end
