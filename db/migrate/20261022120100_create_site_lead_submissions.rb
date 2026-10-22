# frozen_string_literal: true

# Um evento recebido no webhook de um Site (ver Site) — lead de formulário
# (nome/email/telefone) ou etapa de compra de e-commerce (produtos/value/
# moeda), vindos de uma tag do Google Tag Manager. Mesmo padrão de
# "colunas dedicadas pra atribuição conhecida + jsonb catch-all" já usado
# em ad_leads: raw_payload sempre guarda o corpo bruto inteiro, então nada
# se perde mesmo quando Sites::WebhookPayloadParser não reconhece um campo.
class CreateSiteLeadSubmissions < ActiveRecord::Migration[7.1]
  def change
    create_table :site_lead_submissions, id: :uuid do |t|
      t.uuid    :site_id

      t.string  :event_name
      t.string  :name
      t.string  :email
      t.string  :phone
      t.decimal :value, precision: 12, scale: 2
      t.string  :currency
      t.string  :transaction_id
      t.jsonb   :product_ids, null: false, default: []
      t.string  :page_url

      t.string  :utm_source
      t.string  :utm_medium
      t.string  :utm_campaign
      t.string  :utm_term
      t.string  :utm_content
      t.string  :utm_id
      t.string  :gclid
      t.string  :fbclid
      t.string  :fbp
      t.string  :fbc
      t.string  :ttclid
      t.string  :msclkid

      t.string  :ip_address
      t.string  :user_agent
      t.jsonb   :raw_payload, null: false, default: {}

      t.timestamps
    end

    add_index :site_lead_submissions, :site_id
    add_index :site_lead_submissions, :created_at
    add_index :site_lead_submissions, :event_name

    add_foreign_key :site_lead_submissions, :sites, on_delete: :nullify
  end
end
