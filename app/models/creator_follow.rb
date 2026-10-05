# frozen_string_literal: true

# == Schema Information
#
# Table name: creator_follows
#
#  id                 :uuid             not null, primary key
#  creator_profile_id :uuid             not null
#  user_id            :uuid             not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# "Seguindo" um vendedor de curso: e o que alimenta a linha de cursos de quem
# voce segue na area do aluno.
#
class CreatorFollow < ApplicationRecord
  # Sem `belongs_to :user` a associacao `CreatorProfile#followers`
  # (through:, source: :user) quebra na hora de resolver.
  belongs_to :creator_profile
  belongs_to :user, foreign_key: :user_id

  validates :user_id, uniqueness: { scope: :creator_profile_id }
end
