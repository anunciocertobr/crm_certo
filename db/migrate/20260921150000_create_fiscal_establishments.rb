class CreateFiscalEstablishments < ActiveRecord::Migration[7.1]
  def change
    create_table :fiscal_establishments, id: :uuid, if_not_exists: true do |t|
      t.string :municipio_ibge_code, null: false, limit: 20
      t.string :municipio_nome, null: false, limit: 255
      t.string :uf, null: false, limit: 2
      t.string :inscricao_municipal, null: false, limit: 30
      t.string :cnae_override, limit: 20
      t.decimal :aliquota_iss_pct, precision: 5, scale: 2, null: false
      t.string :ambiente, null: false, default: 'homologacao', limit: 20
      t.string :provider_key, null: false, limit: 50
      t.text :certificate_content_encrypted
      t.text :certificate_password_encrypted
      t.date :certificate_expires_at
      t.string :rps_serie, null: false, default: '1', limit: 10
      t.integer :rps_numero_atual, null: false, default: 0
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :fiscal_establishments, :municipio_ibge_code, unique: true, if_not_exists: true
    add_index :fiscal_establishments, :provider_key, if_not_exists: true
  end
end
