class CreateIfoodProductCache < ActiveRecord::Migration[7.1]
  def change
    create_table :ifood_product_cache, id: :uuid do |t|
      t.string :ifood_product_id, null: false
      t.string :name
      t.string :image

      t.timestamps
    end
    add_index :ifood_product_cache, :ifood_product_id, unique: true
  end
end
