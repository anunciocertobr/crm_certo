# Disparado por PipelineItem#send_lead_quality_to_meta sempre que
# lead_quality muda (botão "Qualificar Lead" no Kanban). Assíncrono porque
# resolver o pixel do anúncio é uma chamada à Graph API.
#
# META_CONVERSIONS_LEAD_QUALITY_MODE (GlobalConfigService, Configurações >
# Integrações > Meta Conversions API) decide o que vira `value` no evento:
# - "score": manda o lead_score (1-100) direto.
# - "mapped" (padrão): mapeia baixa/media/alta pra 1/5/10 — mais estável pra
#   otimização da Meta quando o score numérico não é usado de forma
#   consistente entre atendentes.
module Meta
  class SendLeadQualityJob < ApplicationJob
    queue_as :low

    QUALITY_VALUE_MAP = { 'baixa' => 1, 'media' => 5, 'alta' => 10 }.freeze

    def perform(pipeline_item_id)
      return unless GlobalConfigService.load('META_CONVERSIONS_ENABLED', 'false') == 'true'

      item = PipelineItem.find_by(id: pipeline_item_id)
      return if item.blank? || item.lead_quality.blank?

      contact = item.contact
      return if contact.blank?

      whatsapp_ad_lead = WhatsappAdLead.where(contact_id: contact.id).order(created_at: :desc).first
      if whatsapp_ad_lead.blank?
        Rails.logger.info "Meta::SendLeadQualityJob: pipeline_item=#{pipeline_item_id} sem WhatsappAdLead — sem anúncio pra atribuir, não envia."
        return
      end

      result = Meta::ConversionsApiService.new.send_event(
        event_name: 'LeadQualified',
        whatsapp_ad_lead: whatsapp_ad_lead,
        contact: contact,
        custom_data: {
          lead_quality: item.lead_quality,
          value: value_for(item),
          currency: 'BRL'
        }
      )

      Rails.logger.error "Meta::SendLeadQualityJob: failed for pipeline_item=#{pipeline_item_id}: #{result.error}" unless result.success
    end

    private

    def value_for(item)
      mode = GlobalConfigService.load('META_CONVERSIONS_LEAD_QUALITY_MODE', 'mapped')
      return item.lead_score if mode == 'score' && item.lead_score.present?

      QUALITY_VALUE_MAP.fetch(item.lead_quality, 0)
    end
  end
end
