# frozen_string_literal: true

# == Schema Information
#
# Table name: course_modules
#
#  id         :uuid             not null, primary key
#  course_id  :uuid             not null
#  position   :integer          default(0), not null
#  title      :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_course_modules_on_course_id              (course_id)
#  index_course_modules_on_course_id_and_position (course_id, position)
#
# Modulo do curso ("Aula 1: fundamentos"). Agrupador de aulas: nao tem video nem
# progresso proprio.
#
class CourseModule < ApplicationRecord
  belongs_to :course
  has_many :course_lessons, -> { order(:position, :created_at) }, dependent: :destroy, inverse_of: :course_module

  accepts_nested_attributes_for :course_lessons, allow_destroy: true

  validates :title, presence: true, length: { maximum: 255 }

  before_validation :assign_position, on: :create

  def duration_seconds
    course_lessons.sum { |lesson| lesson.duration_seconds.to_i }
  end

  private

  def assign_position
    return if position.to_i.positive?

    self.position = (CourseModule.where(course_id: course_id).maximum(:position) || -1) + 1
  end
end
