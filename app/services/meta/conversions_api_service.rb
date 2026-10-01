# Envia eventos server-side pra Meta Conversions API (CAPI) a partir de
# mensagens do WhatsApp — reconstrói o que antes vivia só num workflow n8n
# (ver fluxos de referência do usuário: "mandar dados para a meta" e "Enviar
# o purchase para a Meta"). Documentação do formato pra WhatsApp Business
# Messaging: https://developers.facebook.com/docs/marketing-api/conversions-api/guides/whatsapp
#
# O `ctwa_clid` (Click-to-WhatsApp Click ID) é o que liga o clique no
# anúncio ao evento — só a API oficial o entrega de verdade (Evolution/
# Evolution Go só têm `source_id`, o id do anúncio — ver
# Whatsapp::AdReferralCapture). Sem `ctwa_clid`, a Meta ainda aceita o
# evento mas a atribuição fica mais fraca (só pelo `ph` hasheado).
module Meta
  class ConversionsApiService
    BASE_URL = 'https://graph.facebook.com/v23.0'

    Result = Struct.new(:success, :data, :error, keyword_init: true)

    # Nomes com otimização/relatório nativo no Gerenciador de Eventos da
    # Meta — mas `send_event` aceita QUALQUER string em `event_name`
    # (eventos customizados, ex. "LeadQualified" abaixo), a Meta só não tem
    # um ícone/relatório pronto pra eles.
    STANDARD_EVENTS = %w[Lead Purchase Contact Schedule SubmitApplication CompleteRegistration Message].freeze

    def initialize
      @token = Channel::FacebookPage.first&.user_access_token
    end

    def connected?
      @token.present?
    end

    # whatsapp_ad_lead: o WhatsappAdLead que carrega ad_id/ctwaclid — sem ele
    # (lead que não veio de um clique em anúncio rastreado) o evento não tem
    # como ser enviado com atribuição; a chamada falha explicitamente em vez
    # de mandar um evento "cego" que não ajudaria a otimização da Meta.
    def send_event(event_name:, whatsapp_ad_lead:, contact: nil, custom_data: {}, user_data_overrides: {})
      return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
      return Result.new(success: false, error: 'Lead sem anúncio vinculado (ad_id ausente) — sem atribuição pra mandar.') if whatsapp_ad_lead&.ad_id.blank?

      pixel_result = pixel_id_for_ad(whatsapp_ad_lead.ad_id)
      return pixel_result unless pixel_result.success

      pixel_id = pixel_result.data
      page_id = GlobalConfigService.load('META_CONVERSIONS_PAGE_ID', nil)
      contact ||= whatsapp_ad_lead.contact

      user_data = {
        ph: hash_field(contact&.phone_number),
        ctwa_clid: whatsapp_ad_lead.ctwaclid.presence,
        page_id: page_id
      }.merge(user_data_overrides).compact

      return Result.new(success: false, error: 'user_data vazio (sem telefone nem ctwa_clid) — Meta recusa evento sem identificador.') if user_data.except(:page_id).blank?

      body = {
        data: [
          {
            event_name: event_name,
            event_time: Time.current.to_i,
            action_source: 'business_messaging',
            messaging_channel: 'whatsapp',
            user_data: user_data
          }.tap { |h| h[:custom_data] = custom_data if custom_data.present? }
        ]
      }

      post("/#{pixel_id}/events", body)
    end

    private

    # Resolve o pixel (dataset) vinculado ao anúncio via `tracking_specs` —
    # mesma estratégia do fluxo de referência (lá era um node de código
    # vasculhando a resposta). Cacheado por 12h por ad_id pra não bater na
    # Graph API em todo evento do mesmo anúncio. Fallback pra
    # META_CONVERSIONS_DEFAULT_PIXEL_ID (GlobalConfigService) quando o
    # anúncio não tem tracking_specs (ex.: conta configurada só com 1 pixel
    # pra tudo, associado manualmente no Gerenciador de Eventos).
    def pixel_id_for_ad(ad_id)
      cache_key = "meta_capi_pixel_for_ad_#{ad_id}"
      cached = Rails.cache.read(cache_key)
      return Result.new(success: true, data: cached) if cached.present?

      result = get("/#{ad_id}", fields: 'tracking_specs')
      return Result.new(success: false, error: result.error) unless result.success

      pixel_id = find_pixel_id(result.data['tracking_specs']) || GlobalConfigService.load('META_CONVERSIONS_DEFAULT_PIXEL_ID', nil)
      if pixel_id.blank?
        return Result.new(
          success: false,
          error: "Não encontrei pixel vinculado ao anúncio #{ad_id} (tracking_specs vazio) e " \
                 'META_CONVERSIONS_DEFAULT_PIXEL_ID não está configurado.'
        )
      end

      Rails.cache.write(cache_key, pixel_id, expires_in: 12.hours)
      Result.new(success: true, data: pixel_id)
    end

    def find_pixel_id(tracking_specs)
      Array(tracking_specs).each do |spec|
        pixel = spec['fb_pixel'] || spec[:fb_pixel]
        return Array(pixel).first.to_s if pixel.present?
      end
      nil
    end

    def hash_field(value)
      return nil if value.blank?

      Digest::SHA256.hexdigest(value.to_s.strip.downcase)
    end

    def get(path, params)
      uri = URI("#{BASE_URL}#{path}")
      uri.query = URI.encode_www_form(params.merge(access_token: @token))

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20

      handle(http.request(Net::HTTP::Get.new(uri.request_uri)))
    end

    def post(path, body)
      uri = URI("#{BASE_URL}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request.body = body.merge(access_token: @token).to_json

      handle(http.request(request))
    end

    def handle(response)
      parsed = JSON.parse(response.body)

      unless response.code.to_i.between?(200, 299)
        Rails.logger.error "Meta::ConversionsApiService: #{response.code} #{response.body}"
        return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao enviar evento pra Meta Conversions API.')
      end

      Result.new(success: true, data: parsed)
    rescue StandardError => e
      Rails.logger.error "Meta::ConversionsApiService: error: #{e.message}"
      Result.new(success: false, error: 'Erro inesperado ao falar com a Meta Conversions API.')
    end
  end
end
