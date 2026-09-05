# Troca o code do OAuth do Google (fluxo iniciado em Integrations::App#action)
# pelos tokens e guarda num Integrations::Hook — independente do fluxo de
# e-mail/Gmail (Api::V1::Google::AuthorizationsController), que cria uma
# caixa de atendimento e não deve ser reaproveitado aqui.
#
# Atende DOIS identifiers ('google_workspace', escopo Drive/GTM/GA4, e
# 'google_ads', escopo adwords) na MESMA redirect_uri — Google Ads reaproveita
# a URL já cadastrada nas "Authorized redirect URIs" do client OAuth em vez de
# precisar de uma nova (o usuário evita mexer no Google Cloud Console de novo
# só pra Ads). O identifier salvo no state (ver Integrations::App#encode_state)
# decide em qual Integrations::Hook os tokens são gravados; a resposta devolve
# `app_id` pro frontend saber pra onde navegar depois do login.
class Api::V1::Integrations::GoogleWorkspaceAuthorizationsController < Api::V1::BaseController
  include GoogleConcern

  ALLOWED_IDENTIFIERS = %w[google_workspace google_ads].freeze

  def callback
    code = params[:code]
    state = params[:state]
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Código ou state ausente') unless code && state

    identifier = verify_google_token(state)
    unless ALLOWED_IDENTIFIERS.include?(identifier)
      return error_response(ApiErrorCodes::INVALID_SIGNATURE, 'State inválido ou expirado', status: :unauthorized)
    end

    token_response = google_client.auth_code.get_token(code, redirect_uri: redirect_uri)
    parsed = token_response.response.parsed
    email = decode_email(parsed['id_token'])

    save_hook(identifier, parsed, email)

    success_response(data: { email: email, app_id: identifier })
  rescue StandardError => e
    Rails.logger.error("GoogleWorkspaceAuthorizationsController: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível concluir a autorização com o Google.')
  end

  private

  def redirect_uri
    Integrations::App.google_workspace_integration_url
  end

  def decode_email(id_token)
    return nil if id_token.blank?

    JWT.decode(id_token, nil, false).first['email']
  end

  def save_hook(identifier, parsed, email)
    hook = Integrations::Hook.find_or_initialize_by(app_id: identifier)
    existing_settings = hook.settings || {}
    hook.settings = existing_settings.merge(
      'email' => email,
      'access_token' => parsed['access_token'],
      # O Google só devolve refresh_token no primeiro consentimento; preserva o
      # anterior numa reautorização em que ele venha em branco.
      'refresh_token' => parsed['refresh_token'] || existing_settings['refresh_token'],
      'scope' => parsed['scope'],
      'expires_on' => (Time.current.utc + parsed['expires_in'].to_i.seconds).to_s
    )
    hook.save!
  end
end
