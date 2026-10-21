# Generaliza a tabela de atribuição de anúncio pra qualquer canal de
# mensagem (hoje só WhatsApp tinha captura de verdade; Instagram/Messenger
# vêm em fases futuras) — renomeado agora porque a tabela está com 0 linhas
# reais em produção, o único momento em que isso é de graça (sem migração
# de dado, só referência de código). `platform` continua significando
# "plataforma do anúncio" (meta/google/direct) — `channel` é o canal de
# MENSAGEM por onde o lead chegou (whatsapp/instagram/messenger/tiktok).
#
# As 8 colunas novas cobrem os click-IDs que faltavam pras quatro
# plataformas de anúncio relevantes (Meta, Google, TikTok, Microsoft/Bing)
# — `gclid`/`ctwaclid`/`utm_*` já existiam mas nunca eram escritos em
# nenhum lugar do código antes desta sessão.
class RenameWhatsappAdLeadsToAdLeads < ActiveRecord::Migration[7.1]
  def change
    rename_table :whatsapp_ad_leads, :ad_leads

    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_campaign_id', 'index_ad_leads_on_campaign_id'
    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_contact_id', 'index_ad_leads_on_contact_id'
    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_conversation_id', 'index_ad_leads_on_conversation_id'
    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_created_at', 'index_ad_leads_on_created_at'
    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_ctwaclid', 'index_ad_leads_on_ctwaclid'
    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_enriched', 'index_ad_leads_on_enriched'
    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_message_id', 'index_ad_leads_on_message_id'
    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_platform', 'index_ad_leads_on_platform'
    rename_index :ad_leads, 'index_whatsapp_ad_leads_on_status', 'index_ad_leads_on_status'

    add_column :ad_leads, :channel, :string, null: false, default: 'whatsapp'
    add_index :ad_leads, :channel

    # Click-IDs que faltavam — Meta (fbp/fbc, cookies pro Conversions API),
    # TikTok, Instagram, Messenger, Microsoft/Bing Ads, GA4 (utm_id) e um
    # identificador externo genérico pra dedupe (external_id do CAPI).
    add_column :ad_leads, :ttclid, :string
    add_column :ad_leads, :igclid, :string
    add_column :ad_leads, :mesengerclid, :string
    add_column :ad_leads, :fbp, :string
    add_column :ad_leads, :fbc, :string
    add_column :ad_leads, :utm_id, :string
    add_column :ad_leads, :externalid, :string
    add_column :ad_leads, :msclkid, :string
  end
end
