# Rastreia se um GoogleAdsAsset já foi publicado de verdade na Google Ads
# API (ver Google::AdsAssetPublisher) — distinto de "está salvo aqui como
# rascunho". `google_resource_names` guarda o(s) resourceName(s) que a
# Google devolveu, pra referência futura (ex: um dia desvincular/atualizar).
class AddPublishStateToGoogleAdsAssets < ActiveRecord::Migration[7.1]
  def change
    add_column :google_ads_assets, :published_at, :datetime
    add_column :google_ads_assets, :google_resource_names, :jsonb, default: [], null: false
    add_column :google_ads_assets, :google_customer_id, :string
  end
end
