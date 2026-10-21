# Disparado por PipelineItem#send_conversion_to_meta quando completed_at é
# preenchido (negócio fechado no Kanban) -- ver publish_pipeline_item_completed
# pro mesmo gatilho (completed_at indo de blank pra presente), já usado pro
# dispatcher interno de webhooks. Pedido do Marco: "acho que dá pra mandar se
# foi conversão e valor da conversão além de dados de produto como nome do
# produto ids conteúdo categorias". Assíncrono pelo mesmo motivo do job de
# lead quality (resolver o pixel do anúncio é uma chamada à Graph API).
module Meta
  class SendConversionJob < ApplicationJob
    queue_as :low

    def perform(pipeline_item_id)
      return unless GlobalConfigService.load('META_CONVERSIONS_ENABLED', 'false') == 'true'

      item = PipelineItem.find_by(id: pipeline_item_id)
      return if item.blank? || item.completed_at.blank?

      contact = item.contact
      return if contact.blank?

      ad_lead = AdLead.where(contact_id: contact.id).order(created_at: :desc).first
      if ad_lead.blank?
        Rails.logger.info "Meta::SendConversionJob: pipeline_item=#{pipeline_item_id} sem AdLead — sem anúncio pra atribuir, não envia."
        return
      end

      products = item.pipeline_item_products.includes(:product)
      currency = products.first&.currency || 'BRL'

      result = Meta::ConversionsApiService.new.send_event(
        event_name: 'Purchase',
        ad_lead: ad_lead,
        contact: contact,
        custom_data: {
          value: item.total_value,
          currency: currency,
          content_type: 'product',
          num_items: products.sum(&:quantity),
          content_name: products.map { |pip| pip.product&.name }.compact.first,
          content_category: products.map { |pip| pip.product&.product_category&.name || pip.product&.ml_category }.compact.first,
          content_ids: products.map { |pip| pip.product_id }.compact,
          contents: products.map do |pip|
            { id: pip.product_id, quantity: pip.quantity, item_price: pip.locked_unit_price.to_f }
          end
        }.compact
      )

      Rails.logger.error "Meta::SendConversionJob: failed for pipeline_item=#{pipeline_item_id}: #{result.error}" unless result.success
    end
  end
end
