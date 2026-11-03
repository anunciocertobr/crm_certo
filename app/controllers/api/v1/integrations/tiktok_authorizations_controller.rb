# Troca o code do OAuth do TikTok (fluxo iniciado em
# Integrations::App#action) pelos tokens e guarda num Integrations::Hook
# (app_id: 'tiktok') — mesmo padrão do DropboxAuthorizationsController,
# com o app OAuth próprio do TikTok (TIKTOK_CLIENT_KEY/SECRET em
# GlobalConfig).
class Api::V1::Integrations::TiktokAuthorizationsController < Api::V1::BaseController
  include Tiktok::IntegrationHelper

  TOKEN_URL = 'https://open.tiktokapis.com/v2/oauth/token/'
  USER_INFO_URL = 'https://open.tiktokapis.com/v2/user/info/'

  def callback
    code = params[:code]
    state = params[:state]
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Código ou state ausente') unless code && state

    unless verify_tiktok_token(state) == 'tiktok'
      return error_response(ApiErrorCodes::INVALID_SIGNATURE, 'State inválido ou expirado', status: :unauthorized)
    end

    token_data = exchange_code(code)
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível obter o token do TikTok.', status: :bad_gateway) unless token_data

    profile = fetch_profile(token_data['access_token'])
    save_hook(token_data, profile)

    success_response(data: { display_name: profile&.dig('display_name') })
  rescue StandardError => e
    Rails.logger.error("TiktokAuthorizationsController: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível concluir a autorização com o TikTok.')
  end

  private

  def redirect_uri
    Integrations::App.tiktok_integration_url
  end

  def exchange_code(code)
    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'client_key' => GlobalConfigService.load('TIKTOK_CLIENT_KEY', nil),
                                      'client_secret' => GlobalConfigService.load('TIKTOK_CLIENT_SECRET', nil),
                                      'code' => code,
                                      'grant_type' => 'authorization_code',
                                      'redirect_uri' => redirect_uri
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)
  end

  # https://open.tiktokapis.com/v2/user/info/ exige os campos pedidos via
  # query param `fields` — só os cobertos pelo escopo user.info.basic
  # (open_id/union_id/avatar_url/display_name), os demais exigem escopos
  # extras não pedidos aqui.
  def fetch_profile(access_token)
    return nil if access_token.blank?

    uri = URI(USER_INFO_URL)
    uri.query = URI.encode_www_form(fields: 'open_id,union_id,avatar_url,display_name')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = "Bearer #{access_token}"
    response = http.request(request)
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body).dig('data', 'user')
  rescue StandardError
    nil
  end

  def save_hook(token_data, profile)
    hook = Integrations::Hook.find_or_initialize_by(app_id: 'tiktok')
    existing_settings = hook.settings || {}
    hook.settings = existing_settings.merge(
      'open_id' => profile&.dig('open_id'),
      'display_name' => profile&.dig('display_name'),
      'avatar_url' => profile&.dig('avatar_url'),
      'access_token' => token_data['access_token'],
      # TikTok sempre devolve refresh_token (diferente do Dropbox, que só
      # devolve no primeiro consentimento) — ainda assim preserva o
      # anterior por segurança caso uma resposta futura venha sem ele.
      'refresh_token' => token_data['refresh_token'] || existing_settings['refresh_token'],
      'expires_on' => (Time.current.utc + token_data['expires_in'].to_i.seconds).to_s
    )
    hook.save!
  end
end
