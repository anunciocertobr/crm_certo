# Disparado por PipelineItem#send_lead_quality_to_meta sempre que
# lead_quality muda (botão "Qualificar Lead" no Kanban). Assíncrono porque
# resolver o pixel do anúncio é uma chamada à Graph API.
#
# A Meta não tem um campo nativo de "lead quality" no CAPI (não existe
# parâmetro dedicado documentado) -- o pedido do Marco foi "a meta deve
# aceitar mais de uma forma então coloca os dois campos". Antes este job
# escolhia UM formato pra virar o `value` do evento via
# META_CONVERSIONS_LEAD_QUALITY_MODE; agora manda os dois como chaves livres
# em custom_data (a Meta aceita chaves extras, disponíveis em Conversões
# Personalizadas no Gerenciador de Eventos, mesmo sem otimização nativa):
# - lead_quality_score: o lead_score numérico (1-100) quando preenchido.
# - lead_quality_label: baixa/media/alta mapeado pro inglês (low/medium/high),
#   formato categórico mais comum em integrações de CRM com a Meta.
# `value`/`currency` do evento continuam seguindo
# META_CONVERSIONS_LEAD_QUALITY_MODE como antes (não muda comportamento de
# quem já configurou) -- só os dois campos extras em custom_data são novos.
module Meta
  class SendLeadQualityJob < ApplicationJob
    queue_as :low

    QUALITY_VALUE_MAP = { 'baixa' => 1, 'media' => 5, 'alta' => 10 }.freeze
    QUALITY_LABEL_MAP = { 'baixa' => 'low', 'media' => 'medium', 'alta' => 'high' }.freeze

    def perform(pipeline_item_id)
      return unless GlobalConfigService.load('META_CONVERSIONS_ENABLED', 'false') == 'true'

      item = PipelineItem.find_by(id: pipeline_item_id)
      return if item.blank? || item.lead_quality.blank?

      contact = item.contact
      return if contact.blank?

      ad_lead = AdLead.where(contact_id: contact.id).order(created_at: :desc).first
      if ad_lead.blank?
        Rails.logger.info "Meta::SendLeadQualityJob: pipeline_item=#{pipeline_item_id} sem AdLead — sem anúncio pra atribuir, não envia."
        return
      end

      result = Meta::ConversionsApiService.new.send_event(
        event_name: 'LeadQualified',
        ad_lead: ad_lead,
        contact: contact,
        custom_data: {
          lead_quality: item.lead_quality,
          lead_quality_label: QUALITY_LABEL_MAP[item.lead_quality],
          lead_quality_score: item.lead_score,
          value: value_for(item),
          currency: 'BRL'
        }.compact
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
