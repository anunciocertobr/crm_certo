# Google Meu Negócio (Business Profile) pra tela "Gestor de Posts" — mesma
# conexão Google Workspace já usada por GTM/GA4/YouTube/Calendar (escopo
# business.manage). Três hosts diferentes, porque a API do Business Profile
# foi dividida em vários serviços pelo Google:
#   - mybusinessaccountmanagement: contas acessíveis
#   - mybusinessbusinessinformation: dados/edição da localização + categorias
#   - mybusiness (v4, legada): Local Posts — nunca migrou pras APIs novas
require 'net/http'
require 'uri'
require 'json'

class Google::BusinessProfileService
  ACCOUNT_MANAGEMENT_URL = 'https://mybusinessaccountmanagement.googleapis.com/v1'.freeze
  BUSINESS_INFO_URL = 'https://mybusinessbusinessinformation.googleapis.com/v1'.freeze
  LEGACY_URL = 'https://mybusiness.googleapis.com/v4'.freeze
  # Quarto host — API separada das 3 acima, mesmo escopo OAuth
  # (business.manage), por isso reaproveita o mesmo access_token.
  PERFORMANCE_URL = 'https://businessprofileperformance.googleapis.com/v1'.freeze
  LOCATION_LIST_FIELDS = 'name,title,phoneNumbers,websiteUri,storefrontAddress,openInfo'.freeze
  LOCATION_DETAIL_FIELDS = 'title,phoneNumbers,websiteUri,storefrontAddress,regularHours,specialHours,categories,' \
                           'serviceArea,serviceItems,profile,openInfo,latlng'.freeze
  # Métricas diárias reais do enum DailyMetric (ver developers.google.com/
  # my-business/reference/performance) — fora BUSINESS_CONVERSATIONS e
  # BUSINESS_FOOD_ORDERS, marcadas obsoletas na doc oficial.
  DAILY_METRICS = %w[
    BUSINESS_IMPRESSIONS_DESKTOP_MAPS BUSINESS_IMPRESSIONS_DESKTOP_SEARCH
    BUSINESS_IMPRESSIONS_MOBILE_MAPS BUSINESS_IMPRESSIONS_MOBILE_SEARCH
    BUSINESS_DIRECTION_REQUESTS CALL_CLICKS WEBSITE_CLICKS MESSAGING_CLICKS
    BUSINESS_BOOKINGS BUSINESS_FOOD_MENU_CLICKS
  ].freeze

  class Error < StandardError; end

  def accounts
    get(ACCOUNT_MANAGEMENT_URL, 'accounts')['accounts'] || []
  end

  # Achata accounts -> locations numa lista só, já com account_name e
  # location_id (extraído de "locations/{id}") anexados a cada item — os
  # dois são necessários pra montar o path da API legada de Local Posts.
  def all_locations
    accounts.flat_map do |account|
      account_name = account['name']
      locations = get(BUSINESS_INFO_URL, "#{account_name}/locations", fields: LOCATION_LIST_FIELDS)['locations'] || []
      locations.map do |location|
        location.merge('account_name' => account_name, 'location_id' => location['name'].to_s.delete_prefix('locations/'))
      end
    end
  end

  def location(location_name)
    get(BUSINESS_INFO_URL, location_name, fields: LOCATION_DETAIL_FIELDS)
  end

  def update_location(location_name, fields:, update_mask:)
    patch(BUSINESS_INFO_URL, location_name, fields, update_mask: update_mask.join(','))
  end

  def search_categories(query, region_code: 'BR', language_code: 'pt-BR')
    result = get(
      BUSINESS_INFO_URL, 'categories',
      view: 'BASIC', regionCode: region_code, languageCode: language_code, filter: "displayName=#{query}"
    )
    result['categories'] || []
  end

  def posts(account_name, location_id)
    result = get(LEGACY_URL, "#{account_name}/locations/#{location_id}/localPosts")
    result['localPosts'] || []
  end

  # params: summary:, media_url:, cta_action_type: nil, cta_url: nil
  def create_post(account_name, location_id, params)
    body = {
      languageCode: 'pt-BR',
      summary: params[:summary],
      topicType: 'STANDARD',
      media: [{ mediaFormat: 'PHOTO', sourceUrl: params[:media_url] }],
      callToAction: params[:cta_action_type].present? ? { actionType: params[:cta_action_type], url: params[:cta_url] }.compact : nil
    }.compact

    post(LEGACY_URL, "#{account_name}/locations/#{location_id}/localPosts", body)
  end

  def delete_post(post_name)
    delete(LEGACY_URL, post_name)
  end

  # Métricas de desempenho (visualizações no Maps/Busca, cliques pra
  # ligar/site/mensagem, pedidos de rota etc.) — API separada
  # (businessprofileperformance), substituiu o antigo `reportInsights` da
  # v4 (deprecado). `location_name` no formato "locations/{id}" (mesmo
  # formato devolvido por #all_locations). Achata a resposta pra
  # {metric => [{date:, value:}]}, mais fácil de consumir no relatório do
  # que o formato aninhado original da API.
  #
  # ⚠️ Testado em 03/11/2026 só até confirmar que a REQUISIÇÃO está bem
  # formada (dailyMetrics repetido + dailyRange.*.year/month/day — erro de
  # argumento corrigido nesse teste) — a API devolveu 403 "Business Profile
  # Performance API has not been used in project ... or it is disabled",
  # porque essa API específica (businessprofileperformance.googleapis.com)
  # nunca foi habilitada no projeto Google Cloud usado por esta conta,
  # diferente das outras 3 (account management/business info/legacy) que
  # já funcionam. Precisa ser habilitada manualmente em
  # https://console.developers.google.com/apis/api/businessprofileperformance.googleapis.com/overview
  # (ação do dono da conta Google, não é código) antes de dar pra confirmar
  # dado real.
  def performance(location_name, date_start:, date_stop:)
    params = { dailyMetrics: DAILY_METRICS }
    params.merge!(date_range_params('dailyRange.start_date', date_start))
    params.merge!(date_range_params('dailyRange.end_date', date_stop))

    result = get(PERFORMANCE_URL, "#{location_name}:fetchMultiDailyMetricsTimeSeries", **params)
    flatten_performance(result)
  end

  private

  def date_range_params(prefix, date_string)
    date = date_string.is_a?(Date) ? date_string : Date.parse(date_string)
    { "#{prefix}.year" => date.year, "#{prefix}.month" => date.month, "#{prefix}.day" => date.day }
  end

  def flatten_performance(result)
    series = result.dig('multiDailyMetricTimeSeries', 0, 'dailyMetricTimeSeries') || []
    series.each_with_object({}) do |entry, acc|
      dated_values = entry.dig('timeSeries', 'datedValues') || []
      acc[entry['dailyMetric']] = dated_values.map do |dv|
        d = dv['date'] || {}
        { 'date' => format('%04d-%02d-%02d', d['year'], d['month'], d['day'] || 1), 'value' => dv['value'].to_i }
      end
    end
  end

  def access_token
    Google::WorkspaceTokenService.new.access_token
  end

  def request(method_class, base_url, path, query_params = {}, body = nil)
    uri = URI("#{base_url}/#{path}")
    uri.query = URI.encode_www_form(query_params) if query_params.present?

    response = http_client(uri).request(build_request(method_class, uri, body))
    parsed = response.body.present? ? JSON.parse(response.body) : {}

    raise Error, "#{parsed.dig('error', 'code')} - #{parsed.dig('error', 'message')}" if parsed['error'].present?

    parsed
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da API do Google Meu Negócio: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao consultar a API do Google Meu Negócio.'
  end

  def http_client(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10
    http
  end

  def build_request(method_class, uri, body)
    token = access_token
    raise Error, 'Conexão com o Google não encontrada. Conecte em Configurações > Integrações.' if token.blank?

    request = method_class.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    if body
      request['Content-Type'] = 'application/json'
      request.body = body.to_json
    end
    request
  end

  def get(base_url, path, **params)
    request(Net::HTTP::Get, base_url, path, params)
  end

  def patch(base_url, path, body, **params)
    request(Net::HTTP::Patch, base_url, path, params, body)
  end

  def post(base_url, path, body)
    request(Net::HTTP::Post, base_url, path, {}, body)
  end

  def delete(base_url, path)
    request(Net::HTTP::Delete, base_url, path)
  end
end
