# Ingress do webhook de um Site (Dashboards > Sites) — chamado pelo
# NAVEGADOR DO VISITANTE via uma tag do Google Tag Manager do cliente, não
# máquina-a-máquina (ver config/initializers/cors.rb, bloco liberando
# origin '*' só pra este path). Autenticado só pelo webhook_token no path
# (Site#webhook_token, has_secure_token) — sem assinatura/HMAC, já que o
# GTM não tem como assinar o payload. `ActionController::API` puro, igual
# Api::V1::Webhooks::NinetyNineController.
class Api::V1::Webhooks::SitesController < ActionController::API
  MAX_BODY_BYTES = 200.kilobytes

  # Todo campo que Sites::WebhookPayloadParser sabe preencher — usado via
  # `slice` pra montar o create (em vez de listar campo por campo), assim
  # um campo novo adicionado só no parser não fica esquecido aqui.
  PARSED_ATTRIBUTE_KEYS = %i[
    event_name name email phone value currency transaction_id product_ids
    content_category page_url utm_source utm_medium utm_campaign utm_term
    utm_content utm_id gclid fbclid fbp fbc ttclid msclkid payment_method
    action_source gender birth_date address_city address_state address_zip
    address_country
  ].freeze

  before_action :set_site!

  def receive
    raw = request.raw_post.to_s
    return render(json: { received: false, error: 'payload too large' }, status: :payload_too_large) if raw.bytesize > MAX_BODY_BYTES

    payload = JSON.parse(raw)
    payload = {} unless payload.is_a?(Hash)
    parsed = Sites::WebhookPayloadParser.call(payload)

    SiteLeadSubmission.create!(
      parsed.slice(*PARSED_ATTRIBUTE_KEYS).merge(
        site: @site,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        raw_payload: payload
      )
    )

    render json: { received: true }, status: :ok
  rescue JSON::ParserError
    render json: { received: false, error: 'invalid JSON' }, status: :bad_request
  rescue StandardError => e
    Rails.logger.error("[SITE_WEBHOOK] site=#{@site&.id} failed: #{e.class}: #{e.message}")
    # Sempre 200 pro GTM não ficar reenviando o mesmo evento indefinidamente —
    # o erro fica logado pra investigar.
    render json: { received: true, warning: 'stored partially' }, status: :ok
  end

  private

  def set_site!
    @site = Site.find_by(webhook_token: params[:token])
    render(json: { received: false, error: 'invalid token' }, status: :unauthorized) if @site.blank? || !@site.active?
  end
end
