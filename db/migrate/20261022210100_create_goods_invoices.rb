# frozen_string_literal: true

# NF-e 55 (mercadoria/e-commerce) e NFC-e 65 (balcão/delivery) — modelo
# único pros dois (campo `modelo`), igual o protótipo front-end antigo
# (public/nota-fiscal.html) já tratava os dois num só fluxo.
#
# Os campos de imposto abaixo espelham Tax::CalculationService::Result
# (já usado em /products/:id/calcular_imposto) — reaproveitado aqui em vez
# de duplicar a lógica de IBS/CBS/Imposto Seletivo/legado: cada item usa
# esse serviço (produto + quantidade + preço) e os valores da nota são a
# soma dos itens. Ver GoodsInvoices::EmissionService.
class CreateGoodsInvoices < ActiveRecord::Migration[7.1]
  def change
    create_table :goods_invoices, id: :uuid do |t|
      t.references :goods_fiscal_profile, null: false, type: :uuid, foreign_key: true
      t.references :work_order, null: true, type: :uuid, foreign_key: true

      t.string :modelo, null: false # '55' NF-e | '65' NFC-e
      t.string :numero, null: false
      t.string :serie, null: false
      t.string :natureza_operacao, null: false, default: 'Venda de mercadoria'
      t.string :status, null: false, default: 'pending'

      t.string :chave_acesso
      t.string :protocolo
      t.datetime :data_emissao

      # Nulo em NFC-e de consumidor não identificado (comum em balcão).
      t.string :destinatario_nome
      t.string :destinatario_cpf_cnpj
      t.jsonb :destinatario_endereco, default: {}

      # [{ product_id, descricao, ncm, cfop, cst_csosn, origem, quantidade,
      #    valor_unitario, valor_total, cclasstrib, impostos: {<Result#to_h
      #    do item>} }, ...] — impostos de cada item ficam gravados aqui pra
      # auditoria, além de somados nos agregados da nota abaixo.
      t.jsonb :itens, null: false, default: []

      t.decimal :valor_produtos, precision: 15, scale: 2, null: false, default: 0
      t.decimal :valor_desconto, precision: 15, scale: 2, null: false, default: 0
      t.decimal :valor_frete, precision: 15, scale: 2, null: false, default: 0
      t.decimal :valor_total, precision: 15, scale: 2, null: false, default: 0

      # Agregados de Tax::CalculationService::Result somados por todos os
      # itens — regime vem do GlobalConfig da empresa (mesmo pra nota
      # inteira, não varia por item).
      t.string :regime_tributario
      t.decimal :valor_cbs, precision: 15, scale: 2, null: false, default: 0
      t.decimal :valor_ibs, precision: 15, scale: 2, null: false, default: 0
      t.decimal :valor_imposto_seletivo, precision: 15, scale: 2, null: false, default: 0
      t.decimal :valor_legado, precision: 15, scale: 2, null: false, default: 0
      t.decimal :valor_total_impostos, precision: 15, scale: 2, null: false, default: 0
      # Avisos de configuração ausente (CST/alíquota não cadastrada etc.),
      # deduplicados entre os itens — mesmo texto de Tax::CalculationService.
      t.jsonb :avisos_fiscais, null: false, default: []

      t.text :xml_envio
      t.text :xml_retorno
      t.text :erro_mensagem

      t.timestamps
    end

    add_index :goods_invoices, %i[goods_fiscal_profile_id serie numero modelo], unique: true,
                                                                                 name: 'idx_goods_invoices_numeracao'
    add_index :goods_invoices, :status
    add_index :goods_invoices, :chave_acesso
  end
end
