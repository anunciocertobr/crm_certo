require 'net/http'

# Google::AdsInsightsService - substitui o workflow n8n "Google Ads Relatorio"
# chamando a Google Ads API (v19, GAQL) direto. O refresh_token vem do login
# real com o Google (Api::V1::Integrations::GoogleAdsAuthorizationsController),
# guardado em Integrations::Hook(app_id: 'google_ads'); client_id/secret são o
# MESMO app OAuth do google_workspace (GOOGLE_OAUTH_CLIENT_ID/SECRET) — não
# ficam no hook. developer_token é uma credencial única do sistema
# (GlobalConfig GOOGLE_ADS_DEVELOPER_TOKEN), exigida pela API além do OAuth.
class Google::AdsInsightsService
  TOKEN_URL = 'https://www.googleapis.com/oauth2/v3/token'
  BASE_URL = 'https://googleads.googleapis.com/v19'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_ads')
  end

  def connected?
    @hook&.settings.present?
  end

  def campaigns(date_start:, date_stop:)
    search(<<~GAQL)
      SELECT customer.descriptive_name,
             campaign.id,
             campaign.name,
             campaign.status,
             campaign.advertising_channel_type,
             metrics.clicks,
             metrics.impressions,
             metrics.cost_micros,
             metrics.average_cpc,
             metrics.ctr,
             metrics.conversions,
             metrics.conversions_value
      FROM campaign
      WHERE segments.date BETWEEN '#{date_start}' AND '#{date_stop}'
    GAQL
  end

  def account_cost(date_start:, date_stop:)
    search(<<~GAQL)
      SELECT customer.descriptive_name, metrics.cost_micros
      FROM customer
      WHERE segments.date BETWEEN '#{date_start}' AND '#{date_stop}'
    GAQL
  end

  def top_search_terms(date_start:, date_stop:, order_by: 'metrics.impressions', limit: 20)
    search(<<~GAQL)
      SELECT search_term_view.search_term,
             campaign.id,
             campaign.name,
             campaign.status,
             metrics.impressions,
             metrics.clicks,
             metrics.cost_micros
      FROM search_term_view
      WHERE segments.date BETWEEN '#{date_start}' AND '#{date_stop}'
      ORDER BY #{order_by} DESC
      LIMIT #{limit}
    GAQL
  end

  # Lista as contas de anúncios que a conta Google autenticada enxerga
  # (contas próprias + o que uma MCC gerencia), pro passo de escolha depois
  # do login — GET .../customers:listAccessibleCustomers não exige customer_id
  # nenhum, só o access_token + developer_token. Pra cada ID tenta uma
  # consulta GAQL leve pra trazer o nome; se falhar (ex.: sub-conta que
  # exige login-customer-id da MCC pra ser lida), devolve só o ID mesmo.
  def accessible_customers
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    token = access_token
    return Result.new(success: false, error: 'Falha ao renovar o token do Google Ads.') unless token

    developer_token = GlobalConfigService.load('GOOGLE_ADS_DEVELOPER_TOKEN', nil)
    return Result.new(success: false, error: 'Developer Token do Google Ads não configurado.') if developer_token.blank?

    uri = URI("#{BASE_URL}/customers:listAccessibleCustomers")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['developer-token'] = developer_token

    response = http.request(request)
    body = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::AdsInsightsService: accessible_customers -> #{response.code} #{response.body}"
      return Result.new(success: false, error: body.dig('error', 'message') || 'Falha ao listar contas do Google Ads.')
    end

    ids = (body['resourceNames'] || []).map { |name| name.split('/').last }
    Result.new(success: true, data: ids.map { |id| customer_summary(id, token, developer_token) })
  rescue StandardError => e
    Rails.logger.error "Google::AdsInsightsService: accessible_customers error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao listar contas do Google Ads.')
  end

  private

  def customer_summary(customer_id, token, developer_token)
    uri = URI("#{BASE_URL}/customers/#{customer_id}/googleAds:search")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['developer-token'] = developer_token
    request['Content-Type'] = 'application/json'
    request.body = { query: 'SELECT customer.descriptive_name, customer.manager FROM customer LIMIT 1' }.to_json

    response = http.request(request)
    body = JSON.parse(response.body)
    row = response.code.to_i.between?(200, 299) ? body.dig('results', 0, 'customer') : nil

    { id: customer_id, name: row && row['descriptiveName'], manager: row && row['manager'] == true }
  rescue StandardError
    { id: customer_id, name: nil, manager: false }
  end

  def search(query)
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    token = access_token
    return Result.new(success: false, error: 'Falha ao renovar o token do Google Ads.') unless token

    settings = @hook.settings
    customer_id = settings['customer_id'].to_s.gsub(/\D/, '')

    uri = URI("#{BASE_URL}/customers/#{customer_id}/googleAds:search")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['developer-token'] = GlobalConfigService.load('GOOGLE_ADS_DEVELOPER_TOKEN', nil)
    login_customer_id = settings['login_customer_id'].to_s.gsub(/\D/, '')
    request['login-customer-id'] = login_customer_id if login_customer_id.present?
    request['Content-Type'] = 'application/json'
    request.body = { query: query }.to_json

    response = http.request(request)
    body = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::AdsInsightsService: search -> #{response.code} #{response.body}"
      return Result.new(success: false, error: body.is_a?(Array) ? body.dig(0, 'error', 'message') : body.dig('error', 'message'))
    end

    Result.new(success: true, data: body['results'] || [])
  rescue StandardError => e
    Rails.logger.error "Google::AdsInsightsService: search error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a Google Ads API.')
  end

  # Sem refresh automático salvo de volta (ao contrário de
  # Google::WorkspaceTokenService) porque esse token não expira o hook — o
  # refresh_token é estável; só o access_token de curta duração é gerado a
  # cada chamada. Simples e sem estado pra manter.
  def access_token
    settings = @hook.settings
    uri = URI(TOKEN_URL)
    response = Net::HTTP.post_form(uri, {
                                      'grant_type' => 'refresh_token',
                                      'client_id' => GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil),
                                      'client_secret' => GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_SECRET', nil),
                                      'refresh_token' => settings['refresh_token']
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)['access_token']
  rescue StandardError => e
    Rails.logger.error "Google::AdsInsightsService: token refresh error: #{e.message}"
    nil
  end
end
