# frozen_string_literal: true

# Site cadastrado por URL (aba Dashboards > Sites) — card com favicon/nome
# extraído do <title>, e um webhook próprio (webhook_token) pra receber
# eventos de formulário/e-commerce vindos do Google Tag Manager do cliente
# (ver SiteLeadSubmission).
class CreateSites < ActiveRecord::Migration[7.1]
  def change
    create_table :sites, id: :uuid do |t|
      t.string  :url, null: false
      t.string  :name
      t.string  :hostname
      t.string  :webhook_token
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :sites, :webhook_token, unique: true
    add_index :sites, :hostname
  end
end
