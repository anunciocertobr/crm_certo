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
    # `rename_table` no adapter de Postgres do Rails já renomeia sozinho os
    # índices e a sequence que seguem a convenção `index_<tabela>_on_<col>`
    # — confirmado ao vivo (21/10): chamar `rename_index` depois disso dá
    # "relation ... does not exist" porque o nome antigo já não existe mais
    # (o próprio `rename_table` já tinha renomeado). Não precisa (e não
    # pode) renomear de novo à mão.
    rename_table :whatsapp_ad_leads, :ad_leads

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
