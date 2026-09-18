# Rascunhos locais pra planejamento de Google Ads — públicos personalizados,
# grupos de palavras-chave e conjuntos de títulos/descrições (RSA). Não existe
# integração de API ativa ainda (falta developer token/conta selecionada,
# ver Integrations::Hook app_id "google_ads"), então isso só guarda o que o
# usuário monta pra, no futuro, empurrar pra API de verdade — mesmo espírito
# do TargetingList (listas de direcionamento da Meta), mas com um campo
# `kind` pra distinguir os 3 tipos num único lugar.
class CreateGoogleAdsAssets < ActiveRecord::Migration[7.1]
  def change
    create_table :google_ads_assets, id: :uuid, default: -> { 'gen_random_uuid()' }, if_not_exists: true do |t|
      t.string :kind, null: false
      t.string :name, null: false
      t.jsonb :payload, default: {}, null: false

      t.timestamps
    end

    add_index :google_ads_assets, :kind, if_not_exists: true
    add_index :google_ads_assets, %i[kind name], unique: true, if_not_exists: true
  end
end
