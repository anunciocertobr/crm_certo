# Troca o code do OAuth do Google (fluxo iniciado em Integrations::App#action,
# escopo https://www.googleapis.com/auth/adwords) pelos tokens e guarda num
# Integrations::Hook (app_id: 'google_ads') — reaproveita o mesmo app OAuth
# do google_workspace (GOOGLE_OAUTH_CLIENT_ID/SECRET), não pede client_id/
# secret/refresh_token do usuário. Depois do login, accessible_customers
# lista as contas de anúncios que essa conta Google enxerga (via
# Google::AdsInsightsService) pra o usuário escolher qual conectar, e
# select_customer grava a escolha — só então a integração fica pronta pra
# uso em Google::AdsInsightsService/AdsInfrastructureService.
class Api::V1::Integrations::GoogleAdsAuthorizationsController < Api::V1::BaseController
  include GoogleConcern

  def callback
    code = params[:code]
    state = params[:state]
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Código ou state ausente') unless code && state

    identifier = verify_google_token(state)
    unless identifier == 'google_ads'
      return error_response(ApiErrorCodes::INVALID_SIGNATURE, 'State inválido ou expirado', status: :unauthorized)
    end

    token_response = google_client.auth_code.get_token(code, redirect_uri: redirect_uri)
    parsed = token_response.response.parsed
    email = decode_email(parsed['id_token'])

    save_hook(parsed, email)

    success_response(data: { email: email })
  rescue StandardError => e
    Rails.logger.error("GoogleAdsAuthorizationsController#callback: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível concluir a autorização com o Google.')
  end

  def accessible_customers
    result = Google::AdsInsightsService.new.accessible_customers
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    success_response(data: { customers: result.data })
  end

  def select_customer
    hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_ads')
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Google Ads não conectado.', status: :unprocessable_entity) unless hook

    customer_id = params.require(:customer_id).to_s.gsub(/\D/, '')
    login_customer_id = params[:login_customer_id].to_s.gsub(/\D/, '')

    hook.settings = (hook.settings || {}).merge(
      'customer_id' => customer_id,
      'login_customer_id' => login_customer_id.presence
    ).compact
    hook.save!

    success_response(data: { customer_id: customer_id, login_customer_id: login_customer_id.presence })
  end

  private

  def redirect_uri
    Integrations::App.google_ads_integration_url
  end

  def decode_email(id_token)
    return nil if id_token.blank?

    JWT.decode(id_token, nil, false).first['email']
  end

  def save_hook(parsed, email)
    hook = Integrations::Hook.find_or_initialize_by(app_id: 'google_ads')
    existing_settings = hook.settings || {}
    hook.settings = existing_settings.merge(
      'email' => email,
      'access_token' => parsed['access_token'],
      # O Google só devolve refresh_token no primeiro consentimento; preserva o
      # anterior numa reautorização em que ele venha em branco.
      'refresh_token' => parsed['refresh_token'] || existing_settings['refresh_token'],
      'expires_on' => (Time.current.utc + parsed['expires_in'].to_i.seconds).to_s
    )
    hook.save!
  end
end
