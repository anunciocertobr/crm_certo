# frozen_string_literal: true

# == Schema Information
#
# Table name: course_lessons
#
#  id               :uuid             not null, primary key
#  course_id        :uuid             not null
#  course_module_id :uuid             not null
#  description      :text
#  duration_seconds :integer          default(0), not null
#  is_preview       :boolean          default(FALSE), not null
#  position         :integer          default(0), not null
#  title            :string           not null
#  video_id         :string
#  video_provider   :string
#  video_url        :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Aula = um video. O video e de fora (YouTube/Vimeo): guardamos a URL colada,
# o provider e o id, e montamos o embed na hora de tocar.
#
class CourseLesson < ApplicationRecord
  PROVIDERS = %w[youtube vimeo].freeze

  belongs_to :course_module
  belongs_to :course
  has_one :last_enrollment, lambda {
    # Ultima inscricao que parou exatamente nesta aula.
    course_enrollments.joins(:lesson_progresses)
                      .where(lesson_progresses: { course_lesson_id: id })
                      .order('lesson_progresses.last_watched_at DESC')
  }, class_name: 'CourseEnrollment', foreign_key: :last_lesson_id, inverse_of: :last_lesson

  has_many :lesson_progresses, dependent: :destroy

  validates :title, presence: true, length: { maximum: 255 }
  validates :video_provider, inclusion: { in: PROVIDERS }, allow_nil: true

  before_validation :assign_position, on: :create
  before_validation :parse_video, if: -> { video_url.present? }

  scope :previews, -> { where(is_preview: true) }

  def youtube?
    video_provider == 'youtube'
  end

  def vimeo?
    video_provider == 'vimeo'
  end

  def has_video?
    youtube? || vimeo?
  end

  def embed_url
    Courses::VideoUrlParser.embed_url(video_provider, video_id)
  end

  private

  def assign_position
    return if position.to_i.positive?

    self.position = (CourseLesson.where(course_module_id: course_module_id).maximum(:position) || -1) + 1
  end

  # Aceita a URL colada no editor e extrai provider/id. URL invalida deixa a
  # aula sem video em vez de gravar lixo — quem cadastrou ve o campo vazio e
  # corrige, em vez de o player embocar um iframe quebrado.
  def parse_video
    parsed = Courses::VideoUrlParser.parse(video_url)

    self.video_provider = parsed[:provider]
    self.video_id = parsed[:video_id]
  end
end
