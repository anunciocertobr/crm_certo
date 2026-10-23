# Espelho local dos pedidos recebidos no Mercado Livre — mesmo raciocínio
# do IfoodOrder (20260828120000): persistir aqui dá uma lista estável pra
# tela, em vez de depender da API do ML a cada carregamento.
class CreateMercadoLivreOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :mercado_livre_orders, id: :uuid, if_not_exists: true do |t|
      t.string :ml_order_id, null: false, limit: 100
      t.string :status, null: false, default: 'confirmed', limit: 30
      t.string :customer_name, limit: 255
      t.string :customer_phone, limit: 40
      t.decimal :total_price, precision: 10, scale: 2, null: false, default: 0.0
      t.jsonb :items, null: false, default: []
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :placed_at

      t.timestamps
    end

    add_index :mercado_livre_orders, :ml_order_id, unique: true, if_not_exists: true
    add_index :mercado_livre_orders, :status, if_not_exists: true
    add_index :mercado_livre_orders, :placed_at, if_not_exists: true
  end
end
