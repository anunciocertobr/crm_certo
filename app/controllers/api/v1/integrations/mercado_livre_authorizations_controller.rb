# Troca o code do OAuth do Mercado Livre (fluxo iniciado em
# Integrations::App#build_mercado_livre_action) pelos tokens e guarda num
# Integrations::Hook (app_id: 'mercado_livre') — mesmo padrão do
# DropboxAuthorizationsController, com o app OAuth próprio do Mercado
# Livre (MERCADO_LIVRE_CLIENT_ID/SECRET em GlobalConfig).
#
# NUNCA TESTADO CONTRA A API REAL — sem client_id/client_secret de um app
# ML cadastrado ainda (bloqueado até o Marco criar o app em
# https://developers.mercadolivre.com.br e informar as credenciais). Os
# nomes de campo do token response (access_token/refresh_token/expires_in/
# user_id) seguem a documentação pública do ML; confirmar contra a API real
# assim que houver credencial antes de considerar isso pronto.
class Api::V1::Integrations::MercadoLivreAuthorizationsController < Api::V1::BaseController
  include MercadoLivre::IntegrationHelper

  TOKEN_URL = 'https://api.mercadolibre.com/oauth/token'

  def callback
    code = params[:code]
    state = params[:state]
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Código ou state ausente') unless code && state

    unless verify_mercado_livre_token(state) == 'mercado_livre'
      return error_response(ApiErrorCodes::INVALID_SIGNATURE, 'State inválido ou expirado', status: :unauthorized)
    end

    token_data = exchange_code(code)
    unless token_data
      return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível obter o token do Mercado Livre.',
                             status: :bad_gateway)
    end

    nickname = fetch_nickname(token_data['access_token'], token_data['user_id'])
    save_hook(token_data, nickname)

    success_response(data: { user_id: token_data['user_id'], nickname: nickname })
  rescue StandardError => e
    Rails.logger.error("MercadoLivreAuthorizationsController: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível concluir a autorização com o Mercado Livre.')
  end

  private

  def redirect_uri
    Integrations::App.mercado_livre_integration_url
  end

  def exchange_code(code)
    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'grant_type' => 'authorization_code',
                                      'client_id' => GlobalConfigService.load('MERCADO_LIVRE_CLIENT_ID', nil),
                                      'client_secret' => GlobalConfigService.load('MERCADO_LIVRE_CLIENT_SECRET', nil),
                                      'code' => code,
                                      'redirect_uri' => redirect_uri
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)
  end

  def fetch_nickname(access_token, user_id)
    return nil if access_token.blank? || user_id.blank?

    uri = URI("https://api.mercadolibre.com/users/#{user_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = "Bearer #{access_token}"
    response = http.request(request)
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)['nickname']
  rescue StandardError
    nil
  end

  def save_hook(token_data, nickname)
    hook = Integrations::Hook.find_or_initialize_by(app_id: 'mercado_livre')
    existing_settings = hook.settings || {}
    hook.settings = existing_settings.merge(
      'user_id' => token_data['user_id'].to_s,
      'nickname' => nickname,
      'access_token' => token_data['access_token'],
      # O ML só devolve refresh_token quando o app pediu offline_access (o
      # padrão); preserva o anterior numa reautorização em que venha em branco.
      'refresh_token' => token_data['refresh_token'] || existing_settings['refresh_token'],
      'scope' => token_data['scope'],
      'expires_on' => (Time.current.utc + token_data['expires_in'].to_i.seconds).to_s
    )
    hook.save!
  end
end
