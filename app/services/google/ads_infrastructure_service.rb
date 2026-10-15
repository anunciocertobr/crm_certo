require 'net/http'

# Google::AdsInfrastructureService - substitui o "Gerenciador de
# Infraestrutura Google Ads" (fluxo de 8 passos: sub-conta, ação de
# conversão, conversões aprimoradas, vincular GA4, tracking template,
# lista de remarketing, sitelink, vínculo com o MCC) que originalmente só
# simulava as chamadas com IDs de Math.random(). Usa a mesma credencial de
# Integrations::Hook(app_id: 'google_ads') do Google::AdsInsightsService —
# refresh_token do login real com o Google, client_id/secret do app OAuth
# compartilhado (GOOGLE_OAUTH_CLIENT_ID/SECRET), developer_token único do
# sistema (GlobalConfig GOOGLE_ADS_DEVELOPER_TOKEN) e login_customer_id (o
# MCC, opcional, escolhido junto com o customer_id).
class Google::AdsInfrastructureService
  TOKEN_URL = 'https://www.googleapis.com/oauth2/v3/token'
  BASE_URL = 'https://googleads.googleapis.com/v19'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_ads')
  end

  def connected?
    @hook&.settings.present?
  end

  # Passo 1: cria uma sub-conta (Customer) sob o MCC.
  def create_customer_client(descriptive_name:, currency_code:, time_zone:)
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    mcc = login_customer_id
    return Result.new(success: false, error: 'login_customer_id (MCC) não configurado.') if mcc.blank?

    post("/customers/#{mcc}:createCustomerClient", {
      customerClient: { descriptiveName: descriptive_name, currencyCode: currency_code, timeZone: time_zone }
    })
  end

  # Passo 2: cria uma ação de conversão (categoria PURCHASE, tipo WEBPAGE).
  def create_conversion_action(customer_id:, name:)
    mutate(customer_id, 'conversionActions', [{
      create: { name: name, type: 'WEBPAGE', category: 'PURCHASE', status: 'ENABLED' }
    }])
  end

  # Passo 3: ativa Conversões Aprimoradas na ação de conversão já criada.
  def enable_enhanced_conversions(customer_id:, conversion_action_resource:)
    mutate(customer_id, 'conversionActions', [{
      update: { resourceName: conversion_action_resource, enhancedConversionsForLeadsEnabled: true },
      updateMask: 'enhancedConversionsForLeadsEnabled'
    }])
  end

  # Passo 4: vincula a propriedade GA4 à conta de anúncios.
  def link_ga4(customer_id:, ga4_property_id:)
    mutate(customer_id, 'productLinks', [{ create: { ga4PropertyId: ga4_property_id, status: 'ENABLED' } }])
  end

  # Passo 5: define o Tracking Template global da conta (ValueTrack).
  def set_tracking_template(customer_id:, tracking_template:)
    mutate_single(customer_id, 'customers', {
      update: { resourceName: "customers/#{customer_id}", trackingUrlTemplate: tracking_template },
      updateMask: 'trackingUrlTemplate'
    })
  end

  # Passo 6: cria uma lista de remarketing (visitantes dos últimos 30 dias).
  def create_remarketing_list(customer_id:, name:, membership_days: 30)
    mutate(customer_id, 'userLists', [{
      create: { name: name, membershipLifeSpan: membership_days, basicUserList: { ruleBasedUserListInfo: {} } }
    }])
  end

  # Passo 7: cria um asset de sitelink em nível de conta.
  def create_sitelink_asset(customer_id:, link_text:, final_url:, description1: nil, description2: nil)
    sitelink_asset = { linkText: link_text, finalUrls: [final_url] }
    sitelink_asset[:description1] = description1 if description1.present?
    sitelink_asset[:description2] = description2 if description2.present?
    mutate(customer_id, 'assets', [{ create: { type: 'SITELINK', sitelinkAsset: sitelink_asset } }])
  end

  # Passo 8: vincula a sub-conta ao MCC (relação de gerenciamento).
  def link_manager(customer_id:)
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    mcc = login_customer_id
    return Result.new(success: false, error: 'login_customer_id (MCC) não configurado.') if mcc.blank?

    mutate(customer_id, 'customerManagerLink', [{ create: { managerCustomer: "customers/#{mcc}", status: 'ACTIVE' } }])
  end

  # --- Extensões/ativos da Criação Google Ads (GoogleAdsAsset) ---
  # Cada create_* monta o corpo específico do tipo de Asset e delega pro
  # mutate genérico. Nunca testado contra a API real ainda (nenhuma conta
  # Google Ads tem customer_id selecionado em produção até agora — ver
  # GoogleAdsAuthorizationsController) — os nomes de campo seguem o schema
  # documentado da Google Ads API v19, mas o primeiro publish de verdade
  # pode exigir ajuste fino se algum nome de enum estiver errado (o erro
  # que a Google devolve costuma apontar o campo exato).

  def create_callout_asset(customer_id:, callout_text:)
    mutate(customer_id, 'assets', [{ create: { type: 'CALLOUT', calloutAsset: { calloutText: callout_text } } }])
  end

  def create_structured_snippet_asset(customer_id:, header:, values:)
    mutate(customer_id, 'assets', [{
      create: { type: 'STRUCTURED_SNIPPET', structuredSnippetAsset: { header: header, values: values } }
    }])
  end

  def create_call_asset(customer_id:, country_code:, phone_number:)
    mutate(customer_id, 'assets', [{
      create: { type: 'CALL', callAsset: { countryCode: country_code, phoneNumber: phone_number } }
    }])
  end

  def create_lead_form_asset(customer_id:, business_name:, headline:, description:, call_to_action_type:,
                              privacy_policy_url:, question_fields:)
    mutate(customer_id, 'assets', [{
      create: {
        type: 'LEAD_FORM',
        leadFormAsset: {
          businessName: business_name,
          headline: headline,
          description: description,
          callToActionType: call_to_action_type,
          privacyPolicyUrl: privacy_policy_url,
          fields: question_fields.map { |f| { inputType: f } },
          # Tela de confirmação pós-envio — campos obrigatórios na API,
          # sem equivalente na nossa UI ainda, por isso um texto padrão.
          postSubmitHeadline: 'Obrigado!',
          postSubmitDescription: 'Recebemos seus dados, entraremos em contato em breve.'
        }
      }
    }])
  end

  def create_price_asset(customer_id:, type:, price_qualifier:, offerings:, currency_code: 'BRL',
                          language_code: 'pt-BR')
    price_offerings = offerings.map do |o|
      {
        header: o[:header] || o['header'],
        description: o[:description] || o['description'],
        price: { amountMicros: (price_to_micros(o[:price] || o['price'])), currencyCode: currency_code },
        unit: o[:unit] || o['unit'],
        finalUrls: [o[:finalUrl] || o['finalUrl']]
      }.compact
    end
    price_asset = { type: type, languageCode: language_code, priceOfferings: price_offerings }
    price_asset[:priceQualifier] = price_qualifier if price_qualifier.present?
    mutate(customer_id, 'assets', [{ create: { type: 'PRICE', priceAsset: price_asset } }])
  end

  # `image_base64` já vem sem o prefixo "data:image/...;base64,".
  def create_image_asset(customer_id:, image_base64:, name: nil)
    image_asset = { data: image_base64 }
    create_op = { type: 'IMAGE', imageAsset: image_asset }
    create_op[:name] = name if name.present?
    mutate(customer_id, 'assets', [{ create: create_op }])
  end

  # Liga um asset já criado à CONTA inteira (aparece em todas as campanhas
  # elegíveis) — usado quando a publicação não aponta pra uma campanha
  # específica.
  def link_asset_to_account(customer_id:, asset_resource_name:, field_type:)
    mutate(customer_id, 'customerAssets', [{
      create: { asset: asset_resource_name, fieldType: field_type }
    }])
  end

  # Liga um asset já criado a UMA campanha específica.
  def link_asset_to_campaign(customer_id:, campaign_resource_name:, asset_resource_name:, field_type:)
    mutate(customer_id, 'campaignAssets', [{
      create: { campaign: campaign_resource_name, asset: asset_resource_name, fieldType: field_type }
    }])
  end

  # Listagem leve (sem métricas) pra popular o seletor "publicar nesta
  # campanha" — Google::AdsInsightsService#campaigns é relatório (exige
  # intervalo de datas), este método é só pra escolher o alvo da publicação.
  def list_campaigns(customer_id:)
    search(customer_id, <<~GAQL)
      SELECT campaign.id, campaign.name, campaign.status
      FROM campaign
      WHERE campaign.status != 'REMOVED'
      ORDER BY campaign.name
    GAQL
  end

  private

  def price_to_micros(value)
    (BigDecimal(value.to_s) * 1_000_000).to_i
  end

  def search(customer_id, gaql)
    result = post("/customers/#{customer_id.to_s.gsub(/\D/, '')}/googleAds:search", { query: gaql.squish })
    return result unless result.success

    rows = (result.data['results'] || []).map { |r| r['campaign'] }.compact
    Result.new(success: true, data: rows)
  end

  def login_customer_id
    @hook&.settings&.dig('login_customer_id').to_s.gsub(/\D/, '').presence
  end

  def mutate(customer_id, resource, operations)
    post("/customers/#{customer_id.to_s.gsub(/\D/, '')}/#{resource}:mutate", { operations: operations })
  end

  def mutate_single(customer_id, resource, operation)
    post("/customers/#{customer_id.to_s.gsub(/\D/, '')}/#{resource}:mutate", { operation: operation })
  end

  def post(path, body)
    return Result.new(success: false, error: 'Google Ads não configurado em Integrações.') unless connected?

    token = access_token
    return Result.new(success: false, error: 'Falha ao renovar o token do Google Ads.') unless token

    settings = @hook.settings
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['developer-token'] = GlobalConfigService.load('GOOGLE_ADS_DEVELOPER_TOKEN', nil)
    request['login-customer-id'] = login_customer_id if login_customer_id.present?
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    response = http.request(request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::AdsInfrastructureService: #{path} -> #{response.code} #{response.body}"
      error_msg = parsed.is_a?(Array) ? parsed.dig(0, 'error', 'message') : parsed.dig('error', 'message')
      return Result.new(success: false, error: error_msg || 'Falha ao consultar a Google Ads API.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Google::AdsInfrastructureService: #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a Google Ads API.')
  end

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
    Rails.logger.error "Google::AdsInfrastructureService: token refresh error: #{e.message}"
    nil
  end
end
