# frozen_string_literal: true

require 'net/http'

# Cliente mínimo do Checkout Pro do Mercado Pago (Preferences API):
#   - POST /checkout/preferences → link de pagamento (init_point)
#   - GET  /v1/payments/:id      → status do pagamento (usado pra confirmar)
# Docs: https://www.mercadopago.com.br/developers/pt/docs/checkout-pro-preferences
#
# Credencial: MENU_MERCADOPAGO_ACCESS_SECRET (Access Token da aplicação, em
# Suas integrações > Credenciais). Com o Access Token de TESTE dá pra testar
# com contas/cartões de teste sem cobrar ninguém.
class DigitalMenu::MercadoPagoClient
  BASE_URL = 'https://api.mercadopago.com'
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  class Error < DigitalMenu::CheckoutProviderError; end

  def self.label
    'Mercado Pago'
  end

  def self.access_token
    GlobalConfigService.load('MENU_MERCADOPAGO_ACCESS_SECRET', nil).to_s.strip.presence
  end

  def self.configured?
    access_token.present?
  end

  # Mesma interface do InfinitePayClient. `items` com price em centavos.
  # `order_nsu` vira o external_reference — é por ele que o pagamento
  # aprovado é ligado de volta ao pedido do cardápio.
  def create_link(order_nsu:, items:, redirect_url:, webhook_url:, customer: {})
    payload = {
      external_reference: order_nsu,
      items: items.each_with_index.map do |item, idx|
        {
          id: "item-#{idx + 1}",
          title: item[:description],
          quantity: item[:quantity],
          unit_price: (item[:price].to_i / 100.0).round(2),
          currency_id: 'BRL'
        }
      end,
      back_urls: { success: redirect_url, pending: redirect_url, failure: redirect_url },
      auto_return: 'approved',
      notification_url: webhook_url,
      expires: true,
      expiration_date_to: 2.days.from_now.iso8601(3)
    }
    payer = build_payer(customer)
    payload[:payer] = payer if payer.present?

    body = request(:post, '/checkout/preferences', payload, idempotency_key: "cardapio-#{order_nsu}")
    url = body['init_point'].presence || body['sandbox_init_point'].presence
    raise Error, "Mercado Pago não devolveu o init_point: #{body.inspect.truncate(300)}" if url.blank?

    url
  end

  # { paid:, external_reference:, amount:, paid_amount:, installments:, capture_method:, transaction_id: }
  def payment(payment_id)
    body = request(:get, "/v1/payments/#{payment_id.to_s.gsub(/\D/, '')}")
    amount_cents = (body['transaction_amount'].to_d * 100).round.to_i if body['transaction_amount']
    paid_cents = body.dig('transaction_details', 'total_paid_amount')
    paid_cents = (paid_cents.to_d * 100).round.to_i if paid_cents

    {
      paid: body['status'] == 'approved',
      status: body['status'],
      external_reference: body['external_reference'],
      amount: amount_cents,
      paid_amount: paid_cents || amount_cents,
      installments: body['installments'],
      capture_method: body['payment_method_id'] == 'pix' ? 'pix' : body['payment_type_id'],
      transaction_id: body['id'].to_s
    }
  end

  private

  def build_payer(customer)
    customer = customer.to_h.symbolize_keys
    first, *rest = customer[:full_name].to_s.strip.split(/\s+/)
    phone = customer[:phone].to_s.gsub(/\D/, '').delete_prefix('55')
    payer = {
      name: first.presence,
      surname: rest.join(' ').presence,
      email: customer[:email].to_s.match?(URI::MailTo::EMAIL_REGEXP) ? customer[:email] : nil
    }
    payer[:phone] = { area_code: phone[0, 2], number: phone[2..] } if phone.length >= 10
    zip = customer[:zip].to_s.gsub(/\D/, '')
    if zip.length == 8 && customer[:address].present?
      payer[:address] = { zip_code: zip, street_name: customer[:address], street_number: customer[:number].to_s }
    end
    payer.compact.presence
  end

  def request(method, path, payload = nil, idempotency_key: nil)
    raise Error, 'Access Token do Mercado Pago não configurado' if self.class.access_token.blank?

    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    req = method == :post ? Net::HTTP::Post.new(uri.request_uri) : Net::HTTP::Get.new(uri.request_uri)
    req['Authorization'] = "Bearer #{self.class.access_token}"
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json'
    req['X-Idempotency-Key'] = idempotency_key if idempotency_key
    req.body = payload.to_json if payload

    response = http.request(req)
    parsed = begin
      JSON.parse(response.body.presence || '{}')
    rescue JSON::ParserError
      {}
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "Mercado Pago #{path} HTTP #{response.code}: #{response.body.to_s.truncate(300)}"
    end

    parsed
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
    raise Error, "Mercado Pago #{path} falhou: #{e.class}: #{e.message}"
  end
end
