# frozen_string_literal: true

module Sites
  # Tenta casar os campos conhecidos (nome/email/telefone/valor/utms/etc) de
  # um payload JSON livre vindo do webhook de um Site (ver
  # Webhooks::SitesController) — adaptado de
  # Meta::LeadAds::ImportService::FIELD_NAME_PATTERNS, mas pra um JSON de
  # chave/valor solto em vez do array `{name, values}` da Meta. Tudo
  # melhor-esforço: nunca lança, campo não reconhecido fica de fora do
  # resultado — o controller sempre grava o payload bruto inteiro em
  # `raw_payload` por fora, então nada se perde mesmo quando o parser erra.
  class WebhookPayloadParser
    # Sem âncora de início/fim (igual ao padrão da Meta) — casa com
    # variações comuns tipo "customer_email"/"user_phone" sem precisar
    # listar cada uma.
    FIELD_KEY_PATTERNS = {
      name: /nome|name/i,
      email: /e-?mail/i,
      phone: /telefone|celular|whatsapp|phone/i,
      value: /value|valor|total|amount/i,
      currency: /currency|moeda/i,
      transaction_id: /transaction_id|order_id|pedido_id/i,
      event_name: /event_name|^event$|evento/i,
      page_url: /page_url|page_location|^url$|pagina/i
    }.freeze

    # Chaves já no formato padrão GA4/GTM — lookup direto, sem regex.
    DIRECT_LOOKUP_KEYS = %w[
      utm_source utm_medium utm_campaign utm_term utm_content utm_id
      gclid fbclid fbp fbc ttclid msclkid
    ].freeze

    # Containers comuns que o GTM costuma usar pra agrupar essas variáveis
    # — achata só 1 nível, não tenta adivinhar estrutura arbitrária mais
    # funda que isso. `tracking_properties` é o nome real usado pelo
    # pushToDataLayer() do Cardápio Digital (DigitalMenuPage.tsx) — achado
    # testando com o payload de verdade, não só um exemplo genérico.
    CONTAINER_KEYS = %w[ecommerce user user_data form attribution utm tracking_properties].freeze
    MAX_KEYS_SCANNED = 200
    MAX_PRODUCT_IDS = 50

    def self.call(payload)
      new.call(payload)
    end

    def call(payload)
      return {} unless payload.is_a?(Hash)

      flat = flatten(payload)
      result = {}

      FIELD_KEY_PATTERNS.each do |field, pattern|
        key = flat.keys.find { |k| k.match?(pattern) }
        result[field] = flat[key] if key && flat[key].present?
      end

      DIRECT_LOOKUP_KEYS.each do |key|
        value = flat[key]
        result[key.to_sym] = value if value.present?
      end

      product_ids = extract_product_ids(payload)
      result[:product_ids] = product_ids if product_ids.present?

      result
    rescue StandardError => e
      Rails.logger.warn "Sites::WebhookPayloadParser: #{e.message}"
      {}
    end

    private

    def flatten(obj, depth = 0)
      return {} unless obj.is_a?(Hash)

      result = {}
      obj.each do |key, value|
        break if result.size >= MAX_KEYS_SCANNED

        key_s = key.to_s
        if value.is_a?(Hash) && depth.zero? && CONTAINER_KEYS.include?(key_s.downcase)
          result.merge!(flatten(value, depth + 1))
        elsif !value.is_a?(Hash) && !value.is_a?(Array)
          result[key_s] = value
        end
      end
      result
    end

    def extract_product_ids(payload)
      items = payload['items'] || payload.dig('ecommerce', 'items') || payload['products']
      return [] unless items.is_a?(Array)

      items.first(MAX_PRODUCT_IDS).filter_map do |item|
        next unless item.is_a?(Hash)

        (item['item_id'] || item['id'] || item['sku'])&.to_s
      end
    end
  end
end
