# == Schema Information
#
# Table name: ad_leads
#
#  id              :uuid             not null, primary key
#  ad_name         :string
#  adset_name      :string
#  body            :text
#  campaign_name   :string
#  channel         :string           default("whatsapp"), not null
#  ctwaclid        :string
#  enriched        :boolean          default(FALSE), not null
#  enriched_at     :datetime
#  externalid      :string
#  fbc             :string
#  fbp             :string
#  gclid           :string
#  headline        :string
#  igclid          :string
#  media_type      :string
#  mesengerclid    :string
#  msclkid         :string
#  platform        :string           default("meta"), not null
#  raw_referral    :jsonb            not null
#  source_type     :string
#  source_url      :string
#  status          :string           default("novo"), not null
#  thumbnail_url   :string
#  ttclid          :string
#  utm_campaign    :string
#  utm_content     :string
#  utm_id          :string
#  utm_medium      :string
#  utm_source      :string
#  utm_term        :string
#  valor_venda     :decimal(12, 2)
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  ad_id           :string
#  adset_id        :string
#  campaign_id     :string
#  contact_id      :uuid             not null
#  conversation_id :uuid
#  message_id      :uuid
#  source_id       :string
#
# Indexes
#
#  index_ad_leads_on_campaign_id      (campaign_id)
#  index_ad_leads_on_channel          (channel)
#  index_ad_leads_on_contact_id       (contact_id)
#  index_ad_leads_on_conversation_id  (conversation_id)
#  index_ad_leads_on_created_at       (created_at)
#  index_ad_leads_on_ctwaclid         (ctwaclid)
#  index_ad_leads_on_enriched         (enriched)
#  index_ad_leads_on_message_id       (message_id)
#  index_ad_leads_on_platform         (platform)
#  index_ad_leads_on_status           (status)
#
# Foreign Keys
#
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (message_id => messages.id)
#
# `platform` = plataforma do ANÚNCIO ('meta' | 'google' | 'tiktok' | 'bing' |
# 'direct'). `channel` = canal de MENSAGEM por onde o lead chegou
# ('whatsapp' | 'instagram' | 'messenger' | 'tiktok') — colunas
# independentes, não confundir uma com a outra. Renomeado de
# `WhatsappAdLead`/`whatsapp_ad_leads` em 2026-10-21 (tabela tinha 0 linhas
# reais, único momento sem custo de migração de dado) pra deixar de ser
# WhatsApp-específico — ver captura em Whatsapp::AdReferralCapture e
# Whatsapp::IncomingMessageBaseService#capture_official_ad_referral (ainda
# os únicos caminhos que escrevem aqui; Instagram/Messenger/TikTok ficam
# pra fases futuras).
class AdLead < ApplicationRecord
  belongs_to :contact
  belongs_to :conversation, optional: true
  belongs_to :message, optional: true

  validates :platform, presence: true
  validates :channel, presence: true

  scope :meta, -> { where(platform: 'meta') }
  scope :pending_enrichment, -> { where(enriched: false).where.not(source_id: nil) }
end
