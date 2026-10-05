# frozen_string_literal: true

# == Schema Information
#
# Table name: creator_profiles
#
#  id               :uuid             not null, primary key
#  avatar_url       :string
#  banner_url       :string
#  bio              :text
#  courses_count    :integer          default(0), not null
#  display_name     :string           not null
#  followers_count  :integer          default(0), not null
#  headline         :string
#  is_published     :boolean          default(FALSE), not null
#  pix_key          :string
#  published_at     :datetime
#  slug             :string           not null
#  students_count   :integer          default(0), not null
#  user_id          :uuid             not null
#  whatsapp         :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_creator_profiles_on_is_published  (is_published)
#  index_creator_profiles_on_slug          (slug) UNIQUE
#  index_creator_profiles_on_user_id       (user_id) UNIQUE
#
# Perfil de quem vende curso. O catalogo e global (qualquer usuario logado
# navega), mas publicar exige um perfil — e o perfil e o dono das policies de
# escrita do curso.
#
class CreatorProfile < ApplicationRecord
  belongs_to :user, class_name: 'User'

  has_many :courses, dependent: :destroy
  has_many :creator_follows, dependent: :destroy
  has_many :followers, through: :creator_follows, source: :user

  before_validation :generate_slug, on: :create

  validates :user_id, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true, length: { maximum: 255 },
                   format: { with: /\A[a-z0-9\-]+\z/, message: 'must be lowercase alphanumeric with dashes' }
  validates :display_name, presence: true, length: { maximum: 255 }

  scope :published, -> { where(is_published: true) }
  scope :order_by_name, -> { order(:display_name) }

  # Nome que aparece no card e no topo do curso. Cai para o cadastro do usuario
  # quando o perfil ainda nao tem nome proprio.
  def public_name
    display_name.presence || user&.name.presence || user&.email.presence || 'Criador'
  end

  def followed_by?(other_user)
    return false if other_user.nil?

    creator_follows.exists?(user_id: other_user.id)
  end

  private

  def generate_slug
    return if slug.present?

    base = display_name.to_s.parameterize
    base = "criador-#{SecureRandom.hex(4)}" if base.blank?

    candidate = base
    suffix = 2
    while CreatorProfile.exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end

    self.slug = candidate
  end
end