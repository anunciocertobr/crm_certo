# frozen_string_literal: true

# == Schema Information
#
# Table name: student_course_unlocks
#
#  id               :uuid             not null, primary key
#  failed_attempts  :integer          default(0), not null
#  last_unlocked_at :datetime
#  password_digest  :string           not null
#  user_id          :uuid             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Senha do ALUNO para entrar na area de cursos. O aluno que define a propria
# senha na primeira vez; depois e so destravar.
#
# O digest vive em Courses::PasswordDigest (PBKDF2-HMAC-SHA256, porque nao ha
# bcrypt no bundle). O que fica gravado e o digest, nunca a senha.
#
class StudentCourseUnlock < ApplicationRecord
  # Acima disso o componente trava e pede o login de novo: senha de area e
  # convenience, nao cofre.
  MAX_FAILED_ATTEMPTS = 10

  validates :user_id, presence: true, uniqueness: true
  validates :password_digest, presence: true

  def set_password(password)
    self.password_digest = Courses::PasswordDigest.digest(password)
  end

  def authenticate(password)
    return false if password_digest.blank? || password.blank?

    Courses::PasswordDigest.verify(password, password_digest)
  end

  def locked?
    failed_attempts >= MAX_FAILED_ATTEMPTS
  end

  def register_failure!
    increment!(:failed_attempts)
  end

  def register_success!
    update!(failed_attempts: 0, last_unlocked_at: Time.current)
  end
end
