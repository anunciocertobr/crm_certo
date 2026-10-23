# `ml_category`/`ml_buying_model`/`ml_listing_type`/`ml_condition`/
# `publish_ml` já existiam (20260814140000) — só o esqueleto de campos do
# formulário, sem nada que de fato publicasse. Faltava o id do anúncio já
# publicado (pra saber se é create ou update na próxima sincronização) e
# quando foi publicado pela última vez — e nada equivalente pra Shopee.
class AddMarketplacePublishFieldsToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :ml_item_id, :string, limit: 50
    add_column :products, :ml_published_at, :datetime
    add_column :products, :ml_sync_error, :text

    add_column :products, :publish_shopee, :boolean, null: false, default: false
    add_column :products, :shopee_category_id, :string, limit: 50
    add_column :products, :shopee_item_id, :string, limit: 50
    add_column :products, :shopee_published_at, :datetime
    add_column :products, :shopee_sync_error, :text

    add_index :products, :ml_item_id, if_not_exists: true
    add_index :products, :shopee_item_id, if_not_exists: true
  end
end
