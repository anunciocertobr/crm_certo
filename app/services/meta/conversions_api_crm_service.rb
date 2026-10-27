# "Conversion Leads" / Conversions API for CRM — produto SEPARADO do
# Meta::ConversionsApiService (que exige AdLead com fbc/fbp/ctwa_clid). Serve
# justamente o caso que aquele não cobre: leads de Lead Ads/Instant Forms, que
# a Meta identifica por `leadgen_id`, não por clique rastreado. Mesma Graph
# API/endpoint shape (POST /{dataset_id}/events), mas payload e dataset são
# diferentes — o "CRM dataset" é criado à parte no Events Manager (Meta trata
# como pixel_id internamente, mas não é o pixel de conversão normal da conta).
#
# Setup que precisa existir do lado da Meta ANTES de qualquer envio funcionar
# de verdade (nenhum dos dois é algo que dá pra resolver por código):
#   1. Criar o CRM dataset em Events Manager > Datasource > Settings > Conversion Leads.
#   2. Conseguir um `partner_agent` combinado com o representante da conta Meta.
# Doc oficial: https://developers.facebook.com/documentation/ads-commerce/conversions-api/guides/conversions-api-crm-for-platforms
module Meta
  class ConversionsApiCrmService
    BASE_URL = 'https://graph.facebook.com/v26.0'

    Result = Struct.new(:success, :data, :error, :missing_setup, keyword_init: true)

    # O que falta configurar, em português, pronto pra virar mensagem de
    # aviso na tela (PipelineItemsController usa isso synchronous, antes de
    # enfileirar o job, pra avisar o usuário na hora em vez de só logar).
    def self.setup_status
      missing = []
      missing << 'ativar o envio (Conversion Leads)' if GlobalConfigService.load('META_CRM_ENABLED', 'false') != 'true'
      missing << 'dataset de CRM' if GlobalConfigService.load('META_CRM_DATASET_ID', nil).blank?
      missing << 'partner_agent (combinado com o representante da Meta)' if GlobalConfigService.load('META_CRM_PARTNER_AGENT', nil).blank?
      missing << 'conectar uma página do Facebook' if Channel::FacebookPage.first&.user_access_token.blank?
      missing
    end

    def initialize
      @token = Channel::FacebookPage.first&.user_access_token
    end

    # leadgen_id: o MetaLeadSubmission#leadgen_id (mesmo valor que a Graph API
    # chama de `lead_id` no payload do CRM — ver doc). event_name é o nome do
    # estágio do funil, livre (a Meta não exige um conjunto fixo).
    def send_event(event_name:, leadgen_id:, custom_data: {})
      missing = self.class.setup_status
      if missing.any?
        return Result.new(
          success: false,
          error: "Configuração do Conversion Leads incompleta: #{missing.join(', ')}.",
          missing_setup: missing
        )
      end

      dataset_id = GlobalConfigService.load('META_CRM_DATASET_ID', nil)
      partner_agent = GlobalConfigService.load('META_CRM_PARTNER_AGENT', nil)

      body = {
        data: [
          {
            event_name: event_name,
            event_time: Time.current.to_i,
            action_source: 'system_generated',
            user_data: { lead_id: leadgen_id },
            custom_data: { lead_event_source: 'Anuncio Certo CRM', event_source: 'crm' }.merge(custom_data),
            partner_agent: partner_agent
          }
        ]
      }

      post("/#{dataset_id}/events", body)
    end

    # Envio MANUAL (botão "Enviar pro Meta" na tela "Ver Leads") — paralelo
    # ao send_event acima (que é do fluxo AUTOMÁTICO disparado por mudança
    # de fase/qualidade do Kanban, intocado). Diferenças de propósito:
    #   - dataset_id é parâmetro obrigatório da chamada (quem chama decide,
    #     normalmente o padrão da Página — ver MetaLeadPageSetting — ou um
    #     valor digitado na hora), não lido de GlobalConfig.
    #   - não checa META_CRM_ENABLED/META_CRM_DATASET_ID (configs do fluxo
    #     automático) — só partner_agent + token, que são compartilhados.
    #   - aceita email/phone pra preencher em/ph (hash SHA256) no user_data,
    #     que melhora o match da Meta — o fluxo automático nunca tinha isso.
    # Nunca persiste nada (nem o payload, nem o resultado) no nosso banco —
    # pedido explícito do usuário.
    def send_manual_event(event_name:, leadgen_id:, dataset_id:, email: nil, phone: nil)
      partner_agent = GlobalConfigService.load('META_CRM_PARTNER_AGENT', nil)
      if partner_agent.blank?
        return Result.new(success: false, error: 'Falta configurar o partner_agent (combinado com o representante da Meta).')
      end
      if @token.blank?
        return Result.new(success: false, error: 'Nenhuma Página do Facebook conectada com token válido.')
      end

      user_data = { lead_id: leadgen_id }
      user_data[:em] = [hash_sha256(email)] if email.present?
      user_data[:ph] = [hash_sha256(normalize_phone_digits(phone))] if phone.present?

      body = {
        data: [
          {
            event_name: event_name,
            event_time: Time.current.to_i,
            action_source: 'system_generated',
            user_data: user_data,
            custom_data: { lead_event_source: 'Anuncio Certo CRM', event_source: 'crm' },
            partner_agent: partner_agent
          }
        ]
      }

      post("/#{dataset_id}/events", body)
    end

    private

    # Normalização pro hash de telefone — minúsculo/sem espaço não se aplica
    # a número, só precisa ficar só com dígitos + DDI (mesma convenção de
    # Meta::LeadAds::ImportService#normalize_br_phone: assume Brasil quando
    # faltar o código do país).
    def normalize_phone_digits(raw)
      digits = raw.to_s.gsub(/\D/, '')
      digits.start_with?('55') ? digits : "55#{digits}"
    end

    # Hash exigido pela Meta pra em/ph em texto puro: SHA256 em hexadecimal,
    # minúsculo e sem espaço nas bordas (doc da Conversions API).
    def hash_sha256(value)
      Digest::SHA256.hexdigest(value.to_s.strip.downcase)
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
        Rails.logger.error "Meta::ConversionsApiCrmService: #{response.code} #{response.body}"
        return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao enviar evento pro Conversion Leads da Meta.')
      end

      Result.new(success: true, data: parsed)
    rescue StandardError => e
      Rails.logger.error "Meta::ConversionsApiCrmService: error: #{e.message}"
      Result.new(success: false, error: 'Erro inesperado ao falar com o Conversion Leads da Meta.')
    end
  end
end
