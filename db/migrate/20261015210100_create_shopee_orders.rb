# Espelho local dos pedidos recebidos na Shopee — mesmo raciocínio do
# IfoodOrder/MercadoLivreOrder.
class CreateShopeeOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :shopee_orders, id: :uuid, if_not_exists: true do |t|
      t.string :shopee_order_sn, null: false, limit: 100
      t.string :status, null: false, default: 'UNPAID', limit: 30
      t.string :customer_name, limit: 255
      t.string :customer_phone, limit: 40
      t.decimal :total_price, precision: 10, scale: 2, null: false, default: 0.0
      t.jsonb :items, null: false, default: []
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :placed_at

      t.timestamps
    end

    add_index :shopee_orders, :shopee_order_sn, unique: true, if_not_exists: true
    add_index :shopee_orders, :status, if_not_exists: true
    add_index :shopee_orders, :placed_at, if_not_exists: true
  end
end
