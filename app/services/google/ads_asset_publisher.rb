# Google::AdsAssetPublisher - traduz um GoogleAdsAsset (staging local, kind +
# payload jsonb livre) pra chamadas reais de Google::AdsInfrastructureService,
# e opcionalmente liga o(s) asset(s) criado(s) a uma campanha (ou, sem
# campanha, à conta inteira). Mantém o AdsInfrastructureService genérico
# (só fala a linguagem da Google Ads API) separado da forma como a UI local
# guarda cada tipo de extensão.
class Google::AdsAssetPublisher
  FIELD_TYPE = {
    'sitelink' => 'SITELINK',
    'callout' => 'CALLOUT',
    'structured_snippet' => 'STRUCTURED_SNIPPET',
    'call' => 'CALL',
    'lead_form' => 'LEAD_FORM',
    'price' => 'PRICE',
    'image_asset' => 'IMAGE'
  }.freeze

  Result = Google::AdsInfrastructureService::Result

  def initialize(infrastructure_service: Google::AdsInfrastructureService.new)
    @service = infrastructure_service
  end

  # `campaign_id` opcional — sem ele, liga no nível da conta inteira.
  def publish(google_ads_asset:, customer_id:, campaign_id: nil)
    @customer_id = customer_id
    field_type = FIELD_TYPE.fetch(google_ads_asset.kind) do
      return Result.new(success: false, error: "Tipo de asset '#{google_ads_asset.kind}' não publica na Google Ads API.")
    end

    create_results = create_assets(google_ads_asset)
    failed = create_results.reject(&:success)
    return Result.new(success: false, error: failed.first.error) if failed.any?

    resource_names = create_results.map { |r| r.data.dig('results', 0, 'resourceName') }.compact
    return Result.new(success: false, error: 'A Google não retornou o resource name do asset criado.') if resource_names.empty?

    link_results = resource_names.map { |rn| link_asset(customer_id, rn, field_type, campaign_id) }
    failed_links = link_results.reject(&:success)
    return Result.new(success: false, error: failed_links.first.error, data: { resource_names: resource_names }) if failed_links.any?

    Result.new(success: true, data: { resource_names: resource_names })
  end

  private

  def create_assets(asset)
    payload = asset.payload.with_indifferent_access

    case asset.kind
    when 'sitelink'
      payload['sitelinks'].map do |s|
        s = s.with_indifferent_access
        @service.create_sitelink_asset(
          customer_id: @customer_id, link_text: s['linkText'], final_url: s['finalUrl'],
          description1: s['description1'], description2: s['description2']
        )
      end
    when 'callout'
      payload['callouts'].map { |text| @service.create_callout_asset(customer_id: @customer_id, callout_text: text) }
    when 'structured_snippet'
      [@service.create_structured_snippet_asset(customer_id: @customer_id, header: payload['header'], values: payload['values'])]
    when 'call'
      [@service.create_call_asset(customer_id: @customer_id, country_code: payload['countryCode'], phone_number: payload['phoneNumber'])]
    when 'lead_form'
      [@service.create_lead_form_asset(
        customer_id: @customer_id, business_name: payload['businessName'], headline: payload['headline'],
        description: payload['description'], call_to_action_type: payload['callToAction'],
        privacy_policy_url: payload['privacyPolicyUrl'], question_fields: payload['questions']
      )]
    when 'price'
      [@service.create_price_asset(
        customer_id: @customer_id, type: payload['type'], price_qualifier: payload['priceQualifier'],
        offerings: payload['offerings']
      )]
    when 'image_asset'
      payload['images'].map do |img|
        img = img.with_indifferent_access
        base64 = fetch_image_base64(img['fileUrl'])
        next Result.new(success: false, error: "Falha ao baixar a imagem #{img['fileName']}.") unless base64

        @service.create_image_asset(customer_id: @customer_id, image_base64: base64, name: img['fileName'])
      end
    else
      []
    end
  end

  def link_asset(customer_id, resource_name, field_type, campaign_id)
    if campaign_id.present?
      @service.link_asset_to_campaign(
        customer_id: customer_id, campaign_resource_name: "customers/#{customer_id}/campaigns/#{campaign_id}",
        asset_resource_name: resource_name, field_type: field_type
      )
    else
      @service.link_asset_to_account(customer_id: customer_id, asset_resource_name: resource_name, field_type: field_type)
    end
  end

  def fetch_image_base64(file_url)
    return nil if file_url.blank?

    uri = URI.parse(file_url)
    uri.open { |f| Base64.strict_encode64(f.read) }
  rescue StandardError => e
    Rails.logger.error "Google::AdsAssetPublisher: falha ao baixar imagem #{file_url}: #{e.message}"
    nil
  end
end
