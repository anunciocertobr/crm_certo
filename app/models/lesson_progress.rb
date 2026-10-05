# frozen_string_literal: true

# == Schema Information
#
# Table name: lesson_progresses
#
#  id                   :uuid             not null, primary key
#  completed            :boolean          default(FALSE), not null
#  completed_at         :datetime
#  course_enrollment_id :uuid             not null
#  course_lesson_id     :uuid             not null
#  last_watched_at      :datetime         not null
#  position_seconds     :integer          default(0), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#
# Onde o aluno parou em cada aula. Uma linha por (inscricao, aula).
#
class LessonProgress < ApplicationRecord
  belongs_to :course_enrollment
  belongs_to :course_lesson

  validates :course_enrollment_id, uniqueness: { scope: :course_lesson_id }
  validates :position_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :completed, -> { where(completed: true) }
end
