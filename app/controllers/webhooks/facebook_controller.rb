class Webhooks::FacebookController < ActionController::API
  # This controller handles page object changes from the Facebook webhook —
  # feed (posts/comments) and leadgen (Lead Ads instant forms). The gem
  # facebook-messenger handles messaging events via /bot route separately.
  # Both fields arrive on the same callback URL/payload.

  # Handshake Meta exige ao salvar/trocar a URL de callback de Página no App
  # Dashboard (Webhooks > Page): GET com hub.mode=subscribe, hub.verify_token
  # e hub.challenge — responder o challenge em texto puro só se o token bater
  # com o configurado em Admin > app_configs (grupo 'meta_conversions').
  def verify
    if params['hub.mode'] == 'subscribe' &&
       params['hub.verify_token'] == GlobalConfigService.load('META_WEBHOOK_VERIFY_TOKEN', nil)
      render plain: params['hub.challenge']
    else
      head :forbidden
    end
  end

  def feed_events
    Rails.logger.info('Facebook page webhook received')

    # Payload structure: { "object": "page", "entry": [{ "id": "PAGE_ID", "changes": [...] }] }
    if params['object'].casecmp('page').zero? && params['entry'].present?
      process_page_changes(params['entry'])
      render json: { status: 'received' }
    else
      Rails.logger.warn("Facebook page webhook: Invalid payload structure - object: #{params['object']}")
      head :unprocessable_entity
    end
  end

  private

  def process_page_changes(entries)
    entries.each do |entry|
      page_id = entry['id']
      changes = entry['changes'] || []

      next if changes.empty?

      Rails.logger.info("Processing #{changes.length} page changes for page #{page_id}")

      changes.each do |change|
        # change['value'] chega como ActionController::Parameters — o
        # ActiveJob/Sidekiq não serializa isso sem permit (levanta
        # ActionController::UnfilteredParameters no enqueue, silenciosamente
        # pro chamador já que a resposta HTTP já foi decidida antes).
        # to_unsafe_h é seguro aqui: dado confiável do webhook da Meta, não
        # input de usuário final.
        value = change['value'].respond_to?(:to_unsafe_h) ? change['value'].to_unsafe_h : change['value']

        case change['field']
        when 'feed'
          Webhooks::FacebookFeedEventsJob.perform_later(value, page_id: page_id)
        when 'leadgen'
          Webhooks::FacebookLeadgenEventsJob.perform_later(value, page_id: page_id)
        end
      end
    end
  end
end

