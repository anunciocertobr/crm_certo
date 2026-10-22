# frozen_string_literal: true

# Conferência final contra TODOS os parâmetros da URL da tag "Google Sheet
# relatorio de compra" (GTM do Cardápio Digital Pizzaria) — faltavam ainda:
# content_name/content_type/num_items (var "02/04/07 Parametro"),
# first_name/last_name (separados, a planilha não usa nome completo),
# cupon, e o histórico de compra do cliente (customerTotalOrders/
# customerTotalOrderValue). external_id/first_party_collection também
# entram pra fechar 1:1 com a planilha, mesmo que esta app não tenha como
# preenchê-los ainda (ver Sites::WebhookPayloadParser).
class AddRemainingSheetFieldsToSiteLeadSubmissions < ActiveRecord::Migration[7.1]
  def change
    add_column :site_lead_submissions, :content_name, :jsonb, null: false, default: []
    add_column :site_lead_submissions, :content_type, :string
    add_column :site_lead_submissions, :num_items, :integer
    add_column :site_lead_submissions, :coupon, :string
    add_column :site_lead_submissions, :first_name, :string
    add_column :site_lead_submissions, :last_name, :string
    add_column :site_lead_submissions, :external_id, :string
    add_column :site_lead_submissions, :first_party_collection, :string
    add_column :site_lead_submissions, :customer_total_orders, :integer
    add_column :site_lead_submissions, :customer_total_order_value, :decimal, precision: 12, scale: 2
  end
end
