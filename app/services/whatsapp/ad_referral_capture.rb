# Captura de clique de anúncio (CTWA — Click To WhatsApp) pro formato
# "Baileys" (WhatsApp multi-device não-oficial) — compartilhado entre
# Evolution API clássica e Evolution Go, porque as duas apenas relaiam o
# payload bruto do protocolo WhatsApp (cada uma com seu próprio wrapper
# HTTP/evento), então o bloco `externalAdReplyInfo` aparece na mesma forma
# nos dois, só em profundidades/caminhos potencialmente diferentes dentro do
# JSON — por isso a busca é recursiva por profundidade, não por um caminho
# fixo tipo `message.extendedTextMessage.contextInfo...`.
#
# Esse formato NÃO tem `ctwa_clid` de verdade (esse campo só existe no
# webhook da API oficial — ver Whatsapp::IncomingMessageBaseService
# #capture_official_ad_referral) — o enriquecimento posterior (buscar
# campanha/conjunto/anúncio na Graph API) usa `source_id` (o id do anúncio)
# como chave nesses dois provedores.
module Whatsapp::AdReferralCapture
  private

  def find_external_ad_reply_info(node, depth = 0)
    return nil if depth > 6 || !node.is_a?(Hash)

    direct = node[:externalAdReplyInfo] || node['externalAdReplyInfo']
    return direct if direct.is_a?(Hash)

    node.each_value do |value|
      found = find_external_ad_reply_info(value, depth + 1)
      return found if found
    end

    nil
  end

  def capture_baileys_ad_referral(node:, contact:, conversation:, message:, log_prefix:)
    return if conversation.blank?

    referral = find_external_ad_reply_info(node)
    return if referral.blank?

    WhatsappAdLead.find_or_create_by(conversation_id: conversation.id, platform: 'meta') do |lead|
      lead.contact_id = contact.id
      lead.message_id = message&.id
      lead.source_id = referral[:sourceId]
      lead.source_url = referral[:sourceUrl]
      lead.source_type = referral[:sourceType]
      lead.headline = referral[:title]
      lead.body = referral[:body]
      lead.media_type = referral[:mediaType]
      lead.thumbnail_url = referral[:thumbnailUrl]
      lead.raw_referral = referral
    end
  rescue StandardError => e
    Rails.logger.error "#{log_prefix}: failed to capture ad referral: #{e.message}"
  end
end
