# frozen_string_literal: true

# Endereço do emitente é exigido pela NF-e/NFC-e (<enderEmit>, TEnderEmi) —
# NFS-e não precisava disso porque o estabelecimento já é identificado só
# pela inscrição municipal. forma_pagamento em GoodsInvoice alimenta o
# bloco <pag>/<detPag>, obrigatório em NFC-e (NT 2012/004).
class AddAddressAndPaymentToGoodsFiscal < ActiveRecord::Migration[7.1]
  def change
    change_table :goods_fiscal_profiles do |t|
      t.string :logradouro
      t.string :numero_endereco
      t.string :complemento
      t.string :bairro
      t.string :codigo_municipio
      t.string :nome_municipio
      t.string :cep
      t.string :telefone
    end

    add_column :goods_invoices, :forma_pagamento, :string, null: false, default: '01' # 01 = Dinheiro
  end
end
