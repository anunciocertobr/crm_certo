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
    # payment_method/action_source/gender/birth_date/address_* achados
    # inspecionando a tag "Google Sheet relatorio de compra" de um cliente
    # real (Cardápio Digital Pizzaria) no GTM — é o conjunto de campos que
    # a planilha Google já recebe, replicado aqui pro webhook também ter.
    DIRECT_LOOKUP_KEYS = %w[
      utm_source utm_medium utm_campaign utm_term utm_content utm_id
      gclid fbclid fbp fbc ttclid msclkid
      payment_method action_source gender birth_date
      address_city address_state address_zip address_country
      content_type coupon external_id first_party_collection
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

      content_category = extract_item_field(payload, 'item_category')
      result[:content_category] = content_category if content_category.present?

      content_name = extract_item_field(payload, 'item_name')
      result[:content_name] = content_name if content_name.present?

      num_items = sum_item_quantities(payload)
      result[:num_items] = num_items if num_items.positive?

      first_name, last_name = split_name(result[:name])
      result[:first_name] = first_name if first_name.present?
      result[:last_name] = last_name if last_name.present?

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
      items_from(payload).filter_map do |item|
        (item['item_id'] || item['id'] || item['sku'])&.to_s
      end
    end

    # Categorias únicas dos itens do carrinho (`item_category`) — mesma
    # concatenação que a tag "03 Parametro content_category" do GTM já faz
    # pra planilha, só que como array em vez de string separada por vírgula.
    def extract_item_field(payload, key)
      items_from(payload).filter_map { |item| item[key] }.uniq
    end

    def items_from(payload)
      items = payload['items'] || payload.dig('ecommerce', 'items') || payload['products']
      return [] unless items.is_a?(Array)

      items.first(MAX_PRODUCT_IDS).grep(Hash)
    end

    # Mesmo cálculo que a variável "07 Parametro num_items (quantity)" do
    # GTM já faz via JS (soma de quantity de cada item) — computado aqui em
    # vez de esperar que o front mande um total pronto (evita divergência
    # entre o total mandado e os itens de verdade).
    def sum_item_quantities(payload)
      items_from(payload).sum { |item| item['quantity'].to_i }
    end

    # A planilha usa First Name/Last Name separados (campo de cliente do
    # WooCommerce) — esta app só coleta o nome completo, então divide no
    # primeiro espaço em vez de pedir pro frontend mandar os dois.
    def split_name(full_name)
      return [nil, nil] if full_name.blank?

      first, rest = full_name.to_s.strip.split(' ', 2)
      [first, rest]
    end
  end
end
