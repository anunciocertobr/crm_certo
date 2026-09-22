class CreateServiceInvoices < ActiveRecord::Migration[7.1]
  def change
    create_table :service_invoices, id: :uuid, if_not_exists: true do |t|
      t.references :fiscal_establishment, type: :uuid, null: false, foreign_key: true
      t.references :work_order, type: :uuid, foreign_key: true
      t.string :numero_rps, null: false, limit: 20
      t.string :serie_rps, null: false, limit: 10
      t.string :numero_nfse, limit: 30
      t.string :codigo_verificacao, limit: 50
      t.string :protocolo, limit: 50
      t.string :status, null: false, default: 'pending', limit: 20
      t.string :tomador_nome, null: false, limit: 255
      t.string :tomador_cpf_cnpj, null: false, limit: 20
      t.string :tomador_email, limit: 255
      t.jsonb :tomador_endereco, null: false, default: {}
      t.text :discriminacao, null: false
      t.string :codigo_servico_municipal, null: false, limit: 20
      t.decimal :valor_servicos, precision: 10, scale: 2, null: false
      t.decimal :aliquota_iss_pct, precision: 5, scale: 2, null: false
      t.decimal :valor_iss, precision: 10, scale: 2, null: false
      t.decimal :valor_deducoes, precision: 10, scale: 2, null: false, default: 0
      t.text :xml_envio
      t.text :xml_retorno
      t.text :erro_mensagem

      t.timestamps
    end

    add_index :service_invoices, %i[fiscal_establishment_id serie_rps numero_rps],
              unique: true, if_not_exists: true, name: 'idx_service_invoices_on_rps'
    add_index :service_invoices, :status, if_not_exists: true
    add_index :service_invoices, :numero_nfse, if_not_exists: true
  end
end
