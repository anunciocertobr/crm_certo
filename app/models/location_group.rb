# == Schema Information
#
# Table name: location_groups
#
#  id            :uuid             not null, primary key
#  ad_account_id :string           not null
#  name          :string           not null
#  pins          :jsonb            not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_location_groups_on_ad_account_id  (ad_account_id)
#
# Grupo de localizações (região + raio) salvo por conta de anúncio, pra
# reaproveitar e duplicar na hora de montar o direcionamento geográfico de
# um conjunto de anúncios — ver LocationMapPicker.tsx no frontend e
# Meta::AdsManagerService#create_adset_and_ad (que já converte pin+raio em
# `custom_locations` pra Graph API). Não existe objeto assim na Graph API
# (mesmo raciocínio de TargetingList pra interesses/comportamentos), só que
# aqui o escopo é por conta, não global, porque o pedido explícito foi
# "duplicar tanto pra mesma conta quanto pra outras" — ou seja, listar
# sempre filtra por `ad_account_id`.
class LocationGroup < ApplicationRecord
  validates :name, presence: true
  validates :ad_account_id, presence: true
  validate :validate_pins_structure

  scope :alphabetical, -> { order(:name) }

  private

  def validate_pins_structure
    return unless pins.is_a?(Array)

    if pins.empty?
      errors.add(:pins, 'grupo precisa de pelo menos uma localização')
      return
    end

    pins.each do |pin|
      pin = pin.is_a?(Hash) ? pin.stringify_keys : {}
      next if pin['name'].present? && pin['lat'].is_a?(Numeric) && pin['lng'].is_a?(Numeric) && pin['radius'].is_a?(Numeric)

      errors.add(:pins, 'cada localização precisa de nome, latitude, longitude e raio numéricos')
      break
    end
  end
end
