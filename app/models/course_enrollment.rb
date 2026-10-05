# frozen_string_literal: true

# == Schema Information
#
# Table name: course_enrollments
#
#  id               :uuid             not null, primary key
#  completed_at     :datetime
#  course_id        :uuid             not null
#  last_lesson_id   :uuid
#  last_watched_at  :datetime
#  progress_percent :decimal(5, 2)    default(0.0), not null
#  source           :string           default("free"), not null
#  started_at       :datetime         not null
#  status           :string           default("active"), not null
#  user_id          :uuid             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Inscricao: o vinculo entre aluno e curso. Nasce quando o aluno entra num curso
# gratuito ou quando uma compra e aprovada.
#
class CourseEnrollment < ApplicationRecord
  STATUSES = %w[active completed].freeze
  SOURCES = %w[free purchase].freeze

  belongs_to :course
  belongs_to :last_lesson, class_name: 'CourseLesson', optional: true

  has_many :lesson_progresses, dependent: :destroy
  has_many :course_lessons, through: :lesson_progresses

  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :course_id, uniqueness: { scope: :user_id }

  scope :active, -> { where(status: 'active') }
  scope :completed, -> { where(status: 'completed') }
  scope :recent, -> { order(Arel.sql('COALESCE(last_watched_at, started_at) DESC')) }
  # "Continuar assistindo" na Netflix: o que tem aula começada e nao terminada.
  scope :in_progress, -> { active.where.not(last_watched_at: nil) }

  def completed?
    status == 'completed'
  end

  def progress_percent
    self[:progress_percent].to_f
  end

  # Recalcula o percentual a partir das aulas concluidas. `total` pode ser
  # menor que o total real durante a edicao de um curso: usa o que existe.
  def recalculate_progress!(total_lessons: nil)
    total = total_lessons || course.course_lessons.count
    return if total.zero?

    finished = lesson_progresses.where(completed: true).count
    percent = [(finished * 100.0 / total).round(2), 100.0].min

    newly_completed = percent >= 100.0 && !completed?
    update!(
      progress_percent: percent,
      status: newly_completed ? 'completed' : 'active',
      completed_at: newly_completed ? Time.current : completed_at
    )
  end
end
