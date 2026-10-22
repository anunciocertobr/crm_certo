# Disparado por PipelineItem quando um card ligado a um MetaLeadSubmission
# (lead de Lead Ads/Instant Form, não AdLead de clique) muda de
# qualidade/estágio — manda o status pro "Conversion Leads" da Meta via
# Meta::ConversionsApiCrmService. Item sem MetaLeadSubmission (card criado
# manualmente, ou vindo de outro canal) não é dessa feature — sai sem enviar
# nada, silenciosamente, igual os outros jobs Meta::Send*Job fazem pra AdLead
# ausente.
module Meta
  class SendCrmLeadStatusJob < ApplicationJob
    queue_as :low

    def perform(pipeline_item_id, event_name:)
      item = PipelineItem.find_by(id: pipeline_item_id)
      return if item.blank?

      submission = MetaLeadSubmission.find_by(pipeline_item_id: item.id)
      return if submission.blank?

      result = Meta::ConversionsApiCrmService.new.send_event(
        event_name: event_name,
        leadgen_id: submission.leadgen_id
      )

      return if result.success

      Rails.logger.info "Meta::SendCrmLeadStatusJob: pipeline_item=#{pipeline_item_id} event=#{event_name} not sent: #{result.error}"
    end
  end
end
