# frozen_string_literal: true

# == Schema Information
#
# Table name: course_wishlists
#
#  id         :uuid             not null, primary key
#  course_id  :uuid             not null
#  user_id    :uuid             not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Lista de desejo do aluno.
#
class CourseWishlist < ApplicationRecord
  belongs_to :course

  validates :user_id, uniqueness: { scope: :course_id }

  scope :recent, -> { order(created_at: :desc) }
end
