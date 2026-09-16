# == Schema Information
#
# Table name: targeting_lists
#
#  id         :uuid             not null, primary key
#  items      :jsonb            not null
#  name       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_targeting_lists_on_name  (name) UNIQUE
#
# Lista curada de itens de direcionamento detalhado da Meta (interesses,
# comportamentos, dados demográficos), salva pelo usuário pra reaproveitar
# na hora de montar públicos — ver Meta::AdsManagerService e
# TargetingBuilder.tsx no frontend. `items` é um array de hashes
# {id, name, category, audience_size_lower_bound, audience_size_upper_bound}.
class TargetingList < ApplicationRecord
  validates :name, presence: true, uniqueness: true

  scope :alphabetical, -> { order(:name) }
end
