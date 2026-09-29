# Grupos de localização reutilizáveis pro direcionamento geográfico de
# campanhas Meta (mesmo raciocínio de TargetingList pra interesses/
# comportamentos: não existe objeto assim na Graph API, só o
# `custom_locations` solto dentro do targeting de um conjunto de anúncios —
# isso guarda o recorte de pinos + raio, salvo POR CONTA DE ANÚNCIO
# (diferente de TargetingList, que é global), pra poder duplicar tanto
# dentro da mesma conta quanto pra outra.
class CreateLocationGroups < ActiveRecord::Migration[7.1]
  def change
    create_table :location_groups, id: :uuid, default: -> { 'gen_random_uuid()' }, if_not_exists: true do |t|
      t.string :ad_account_id, null: false
      t.string :name, null: false
      # [{ "name" => "São Paulo", "lat" => -23.55, "lng" => -46.63, "radius" => 15 }, ...]
      t.jsonb :pins, default: [], null: false

      t.timestamps
    end

    add_index :location_groups, :ad_account_id, if_not_exists: true
  end
end
