# == Schema Information
#
# Table name: tiktok_uploads
#
#  id               :uuid             not null, primary key
#  created_by       :uuid             not null
#  error_message    :text
#  privacy_level    :string
#  status           :string           default("pending"), not null
#  title            :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  external_post_id :string
#
# Indexes
#
#  index_tiktok_uploads_on_created_by  (created_by)
#  index_tiktok_uploads_on_status      (status)
#
# Um vídeo do "Gestor de Posts" enviado pra conta TikTok conectada
# (Configurações > Integrações > TikTok). O upload é lento (protocolo em
# 3 passos da Content Posting API), então roda em background — ver
# GestorPosts::TiktokUploadJob e Tiktok::UploadService. Mesmo shape de
# YoutubeUpload, sem `description` (TikTok usa só `title` como legenda)
# e sem privacy_status escolhível pelo usuário ainda (ver comentário na
# migration — forçado privado até o app ser aprovado).
class TiktokUpload < ApplicationRecord
  self.table_name = 'tiktok_uploads'

  has_one_attached :video
  belongs_to :creator, class_name: 'User', foreign_key: :created_by, inverse_of: false

  STATUSES = %w[pending uploading published failed].freeze

  validates :title, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  def mark_uploading!
    update!(status: 'uploading')
  end

  def mark_published!(post_id)
    update!(status: 'published', external_post_id: post_id, error_message: nil)
  end

  def mark_failed!(error)
    update!(status: 'failed', error_message: error.to_s)
  end
end
