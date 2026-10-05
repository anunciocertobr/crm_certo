# frozen_string_literal: true

# == Schema Information
#
# Table name: courses
#
#  id                :uuid             not null, primary key
#  category          :string
#  creator_profile_id:uuid             not null
#  currency          :string           default("BRL"), not null
#  description       :text
#  duration_seconds  :integer          default(0), not null
#  lessons_count     :integer          default(0), not null
#  level             :string           default("iniciante"), not null
#  price_cents       :integer          default(0), not null
#  published_at      :datetime
#  rating_average    :decimal(3, 2)    default(0.0), not null
#  rating_count      :integer          default(0), not null
#  slug              :string           not null
#  status            :string           default("draft"), not null
#  students_count    :integer          default(0), not null
#  subtitle          :string
#  thumbnail_url     :string
#  title             :string           not null
#  trailer_provider  :string
#  trailer_url       :string
#  trailer_video_id  :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#
#  index_courses_on_category           (category)
#  index_courses_on_creator_profile_id (creator_profile_id)
#  index_courses_on_published_at       (published_at)
#  index_courses_on_slug               (slug) UNIQUE
#  index_courses_on_status             (status)
#
class Course < ApplicationRecord
  STATUSES = %w[draft published archived].freeze
  LEVELS = %w[iniciante intermediario avancado].freeze

  belongs_to :creator_profile

  has_many :course_modules, -> { order(:position, :created_at) }, dependent: :destroy, inverse_of: :course
  has_many :course_lessons, dependent: :destroy, inverse_of: :course
  has_many :course_enrollments, dependent: :destroy
  has_many :course_wishlists, dependent: :destroy
  has_many :course_purchase_requests, dependent: :destroy

  accepts_nested_attributes_for :course_modules, allow_destroy: true

  before_validation :generate_slug, on: :create
  # O criador cola a URL do trailer; provider/video_id sao derivados. Sem isso
  # `trailer_embed_url` seria sempre nil mesmo com trailer_url preenchida.
  before_validation :parse_trailer, if: -> { trailer_url.present? }

  validates :slug, presence: true, uniqueness: true, length: { maximum: 255 },
                   format: { with: /\A[a-z0-9\-]+\z/, message: 'must be lowercase alphanumeric with dashes' }
  validates :title, presence: true, length: { maximum: 255 }
  validates :status, inclusion: { in: STATUSES }
  validates :level, inclusion: { in: LEVELS }
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true

  scope :published, -> { where(status: 'published') }
  scope :drafts, -> { where(status: 'draft') }
  scope :free, -> { where(price_cents: 0) }
  scope :paid, -> { where(arel_table[:price_cents].gt(0)) }

  scope :recently_published, -> { published.order(published_at: :desc) }
  scope :by_category, ->(category) { where(category: category) if category.present? }
  scope :search, lambda { |term|
    next if term.blank?

    pattern = "%#{term.to_s.strip}%"
    where('courses.title ILIKE :q OR courses.subtitle ILIKE :q OR courses.description ILIKE :q', q: pattern)
  }

  def parse_trailer
    parsed = Courses::VideoUrlParser.parse(trailer_url)
    self.trailer_provider = parsed[:provider].presence
    self.trailer_video_id = parsed[:video_id].presence
  end

  def free?
    price_cents.zero?
  end

  def paid?
    !free?
  end

  def published?
    status == 'published'
  end

  def price_formatted
    return 'Gratuito' if free?

    ActionController::Base.helpers.number_to_currency(price_cents / 100.0, unit: 'R$ ')
  end

  # Soma das aulas (posicao, titulo e embed do video). Usada na vitrine, onde
  # listar curso nunca deve disparar hundreds de queries.
  def trailer_embed_url
    Courses::VideoUrlParser.embed_url(trailer_provider, trailer_video_id)
  end

  def lessons_in_order
    course_lessons.order(:position, :created_at)
  end

  # Publica o curso: precisa ter pelo menos uma aula com video, senao o aluno
  # pagaria (ou perderia tempo) por uma vitrine sem conteudo.
  def publish!
    raise CourseNotReadyError, 'Adicione ao menos uma aula com video antes de publicar' if lessons_count.zero?

    update!(status: 'published', published_at: published_at || Time.current)
  end

  def unpublish!
    update!(status: 'draft')
  end

  # Recalcula os contadores de cartao. Roda depois de mexer em modulos/aulas.
  def recalculate_stats!
    lessons = course_lessons.to_a

    update_columns(
      lessons_count: lessons.size,
      duration_seconds: lessons.sum { |lesson| lesson.duration_seconds.to_i },
      updated_at: Time.current
    )
  end

  class CourseNotReadyError < StandardError; end

  private

  def generate_slug
    return if slug.present?

    base = title.to_s.parameterize
    base = "curso-#{SecureRandom.hex(4)}" if base.blank?

    candidate = base
    suffix = 2
    while Course.exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end

    self.slug = candidate
  end
end