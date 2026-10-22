# frozen_string_literal: true

# Campos adicionais achados inspecionando a tag "Google Sheet relatorio de
# compra" já configurada no GTM de um cliente real (Cardápio Digital
# Pizzaria) — ela manda bem mais do que o payload inicial cobria:
# categoria/método de pagamento/endereço/dados demográficos/action_source.
# gclid/fbclid/fbp/fbc já existiam desde a migration original.
class AddMoreFieldsToSiteLeadSubmissions < ActiveRecord::Migration[7.1]
  def change
    add_column :site_lead_submissions, :content_category, :jsonb, null: false, default: []
    add_column :site_lead_submissions, :payment_method, :string
    add_column :site_lead_submissions, :action_source, :string
    add_column :site_lead_submissions, :gender, :string
    add_column :site_lead_submissions, :birth_date, :string
    add_column :site_lead_submissions, :address_city, :string
    add_column :site_lead_submissions, :address_state, :string
    add_column :site_lead_submissions, :address_zip, :string
    add_column :site_lead_submissions, :address_country, :string
  end
end
