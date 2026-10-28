# Lista os pixels/datasets de Conversion API da conta de anúncios de onde
# um lead específico veio — usado pelo seletor de dataset do envio manual
# pro Conversion Leads (MetaCrmSendForm.tsx). Antes a lista vinha só de
# datasets já configurados manualmente em alguma Página
# (MetaLeadPageSettingsController#known_dataset_ids); pedido do usuário:
# "deve listar os relacionados àquela conta de anúncios que o lead veio" —
# direto da Graph API, não de uma lista fixa.
module Meta
  class PixelsLookupService
    BASE_URL = 'https://graph.facebook.com/v26.0'

    Result = Struct.new(:success, :data, :error, keyword_init: true)

    def initialize
      @token = Channel::FacebookPage.first&.user_access_token
    end

    def connected?
      @token.present?
    end

    # Descobre a conta de anúncios do anúncio (GET /{ad_id}?fields=account_id)
    # e lista os pixels dela — é o caminho normal (o front manda o ad_id do
    # lead, não a conta direto).
    def pixels_for_ad(ad_id)
      return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
      return Result.new(success: false, error: 'ad_id ausente.') if ad_id.blank?

      account_result = get("/#{ad_id}", fields: 'account_id')
      return account_result unless account_result.success

      account_id = account_result.data['account_id']
      return Result.new(success: false, error: 'Anúncio sem conta de anúncios associada.') if account_id.blank?

      pixels_for_account(account_id)
    end

    def pixels_for_account(ad_account_id)
      return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
      return Result.new(success: false, error: 'ad_account_id ausente.') if ad_account_id.blank?

      id = ad_account_id.to_s.delete_prefix('act_')
      result = get("/act_#{id}/adspixels", fields: 'id,name')
      return result unless result.success

      Result.new(success: true, data: Array(result.data['data']).map { |p| { id: p['id'], name: p['name'] } })
    end

    private

    def get(path, params)
      uri = URI("#{BASE_URL}#{path}")
      uri.query = URI.encode_www_form(params.merge(access_token: @token))

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20

      handle(http.request(Net::HTTP::Get.new(uri.request_uri)))
    end

    def handle(response)
      parsed = JSON.parse(response.body)

      unless response.code.to_i.between?(200, 299)
        Rails.logger.error "Meta::PixelsLookupService: #{response.code} #{response.body}"
        return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao listar pixels da Meta.')
      end

      Result.new(success: true, data: parsed)
    rescue StandardError => e
      Rails.logger.error "Meta::PixelsLookupService: error: #{e.message}"
      Result.new(success: false, error: 'Erro inesperado ao listar pixels da Meta.')
    end
  end
end
