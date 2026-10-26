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
    hook = resolve_hook(identifier, parsed)
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

  # google_workspace continua singleton (find_or_initialize_by sem mais
  # nada). google_ads permite múltiplos hooks (1 por MCC/login — ver
  # config/integration/apps.yml) desde que cada reconexão não apague as
  # outras; por isso aqui a gente primeiro descobre quais contas/MCCs ESSE
  # login enxerga direto (sem expandir árvore nenhuma) pra decidir em qual
  # hook gravar.
  def resolve_hook(identifier, parsed)
    return Integrations::Hook.find_or_initialize_by(app_id: identifier) unless identifier == 'google_ads'

    candidates_result = Google::AdsInsightsService.new(access_token: parsed['access_token']).top_level_customers
    candidates = candidates_result.success ? candidates_result.data : []

    # Caso raro: o login enxerga mais de 1 MCC/conta direto. Guarda os
    # candidatos no próprio hook (ainda sem reference_id) — a tela de
    # Integrações mostra um seletor rápido pra finalizar essa conexão
    # específica antes dela virar utilizável.
    return Integrations::Hook.new(app_id: 'google_ads', settings: { 'pending_candidates' => candidates }) if candidates.size != 1

    reference_id = candidates.first[:id]
    find_or_heal_google_ads_hook(reference_id) || Integrations::Hook.new(app_id: 'google_ads', reference_id: reference_id)
  end

  # Acha o hook já conectado pra esse MCC (reconexão/renovação de token) —
  # inclusive o hook legado único de antes desta mudança, que ainda não
  # tem reference_id preenchido (auto-cura: preenche na hora, comparando
  # contra login_customer_id/customer_id salvos nas settings antigas).
  def find_or_heal_google_ads_hook(reference_id)
    hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_ads', reference_id: reference_id)
    return hook if hook

    normalized = reference_id.to_s.gsub(/\D/, '')
    legacy = Integrations::Hook.account_hooks.where(app_id: 'google_ads', reference_id: nil).find do |h|
      [h.settings['login_customer_id'], h.settings['customer_id']].any? { |v| v.to_s.gsub(/\D/, '') == normalized }
    end
    legacy&.tap { |h| h.reference_id = reference_id }
  end
end
