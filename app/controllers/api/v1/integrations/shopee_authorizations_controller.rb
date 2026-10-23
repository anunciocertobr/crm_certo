# Troca o code do OAuth da Shopee (fluxo iniciado em
# Integrations::App#build_shopee_action) pelos tokens e guarda num
# Integrations::Hook (app_id: 'shopee').
#
# Diferente de ML/Dropbox/Google: a Shopee devolve o `code` E o `shop_id`
# direto na query string do redirect (não só o code), e TODA chamada —
# inclusive a troca do token — exige assinatura HMAC-SHA256 própria
# (partner_id + path + timestamp[ + access_token + shop_id], com o
# partner_key) no corpo/query, não um simples Bearer token na primeira
# troca.
#
# NUNCA TESTADO CONTRA A API REAL — sem partner_id/partner_key de um app
# Shopee cadastrado ainda (bloqueado até o Marco criar o app no Shopee Open
# Platform e informar as credenciais). Confirmar contra a API real assim
# que houver credencial antes de considerar isso pronto.
class Api::V1::Integrations::ShopeeAuthorizationsController < Api::V1::BaseController
  include Shopee::IntegrationHelper

  BASE_URL = 'https://partner.shopeemobile.com'
  TOKEN_PATH = '/api/v2/auth/token/get'

  def callback
    code = params[:code]
    shop_id = params[:shop_id]
    state = params[:state]
    unless code && shop_id && state
      return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Código, shop_id ou state ausente')
    end

    unless verify_shopee_token(state) == 'shopee'
      return error_response(ApiErrorCodes::INVALID_SIGNATURE, 'State inválido ou expirado', status: :unauthorized)
    end

    token_data = exchange_code(code, shop_id)
    unless token_data
      return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível obter o token da Shopee.',
                             status: :bad_gateway)
    end

    shop_name = fetch_shop_name(token_data['access_token'], shop_id)
    save_hook(token_data, shop_id, shop_name)

    success_response(data: { shop_id: shop_id, shop_name: shop_name })
  rescue StandardError => e
    Rails.logger.error("ShopeeAuthorizationsController: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível concluir a autorização com a Shopee.')
  end

  private

  def partner_id
    GlobalConfigService.load('SHOPEE_PARTNER_ID', nil)
  end

  def partner_key
    GlobalConfigService.load('SHOPEE_PARTNER_KEY', nil)
  end

  def signed_query(path, extra = {})
    timestamp = Time.current.to_i
    base_string = "#{partner_id}#{path}#{timestamp}#{extra[:access_token]}#{extra[:shop_id]}"
    sign = OpenSSL::HMAC.hexdigest('SHA256', partner_key, base_string)
    { partner_id: partner_id, timestamp: timestamp, sign: sign }.merge(extra.compact)
  end

  def exchange_code(code, shop_id)
    query = signed_query(TOKEN_PATH)
    uri = URI("#{BASE_URL}#{TOKEN_PATH}")
    uri.query = URI.encode_www_form(query)

    response = Net::HTTP.post(uri, {
      code: code,
      shop_id: shop_id.to_i,
      partner_id: partner_id.to_i
    }.to_json, 'Content-Type' => 'application/json')
    return nil unless response.code.to_i.between?(200, 299)

    parsed = JSON.parse(response.body)
    parsed['error'].present? ? nil : parsed
  end

  def fetch_shop_name(access_token, shop_id)
    return nil if access_token.blank?

    path = '/api/v2/shop/get_shop_info'
    query = signed_query(path, access_token: access_token, shop_id: shop_id.to_i)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(query)

    response = Net::HTTP.get_response(uri)
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)['shop_name']
  rescue StandardError
    nil
  end

  def save_hook(token_data, shop_id, shop_name)
    hook = Integrations::Hook.find_or_initialize_by(app_id: 'shopee')
    existing_settings = hook.settings || {}
    hook.settings = existing_settings.merge(
      'shop_id' => shop_id.to_s,
      'shop_name' => shop_name,
      'access_token' => token_data['access_token'],
      'refresh_token' => token_data['refresh_token'] || existing_settings['refresh_token'],
      'expires_on' => (Time.current.utc + token_data['expire_in'].to_i.seconds).to_s
    )
    hook.save!
  end
end
