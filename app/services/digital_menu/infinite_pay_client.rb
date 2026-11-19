# frozen_string_literal: true

require 'net/http'

# Cliente mínimo do Checkout Integrado da InfinitePay
# (https://www.infinitepay.io/checkout-documentacao). A API só tem dois
# endpoints: criar link (POST /links) e consultar pagamento
# (POST /payment_check). Não há sandbox — todo link criado é real.
#
# Identificação da conta: MENU_INFINITEPAY_HANDLE (InfiniteTag sem o "$")
# e/ou MENU_INFINITEPAY_API_SECRET (chave "inchk_..." enviada no header
# X-Api-Key, só no servidor). Se as duas forem enviadas precisam ser da
# mesma conta, senão a API responde 403.
class DigitalMenu::InfinitePayClient
  BASE_URL = 'https://api.checkout.infinitepay.io'
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  class Error < StandardError; end

  def self.handle
    GlobalConfigService.load('MENU_INFINITEPAY_HANDLE', nil).to_s.strip.delete_prefix('$').presence
  end

  def self.api_key
    GlobalConfigService.load('MENU_INFINITEPAY_API_SECRET', nil).to_s.strip.presence
  end

  # Checkout ligado em Organização > Cardápio Digital E com conta configurada.
  def self.enabled?
    flag = GlobalConfigService.load('MENU_CHECKOUT_ENABLED', nil)
    ActiveModel::Type::Boolean.new.cast(flag) == true && (handle.present? || api_key.present?)
  end

  # Retorna a URL do checkout. `items` = [{ description:, quantity:, price: (centavos) }]
  def create_link(order_nsu:, items:, redirect_url:, webhook_url:, customer: nil, address: nil)
    payload = {
      order_nsu: order_nsu,
      items: items,
      redirect_url: redirect_url,
      webhook_url: webhook_url
    }
    payload[:handle] = self.class.handle if self.class.handle.present?
    payload[:customer] = customer if customer.present?
    payload[:address] = address if address.present?
    # `options` exige API Key. Link de uso único e com validade, pra não ficar
    # um link eterno aceitando pagamentos de um pedido antigo.
    if self.class.api_key.present?
      payload[:options] = {
        single_payment: true,
        valid_until: 2.days.from_now.iso8601
      }
    end

    body = post('/links', payload)
    url = body['url'].presence || body['link'].presence
    raise Error, "InfinitePay não devolveu a URL do link: #{body.inspect.truncate(300)}" if url.blank?

    url
  end

  # { paid: Boolean, amount:, paid_amount:, installments:, capture_method: }
  def payment_check(order_nsu:, transaction_nsu:, slug:)
    payload = { order_nsu: order_nsu, transaction_nsu: transaction_nsu, slug: slug }
    payload[:handle] = self.class.handle if self.class.handle.present?
    body = post('/payment_check', payload)

    {
      paid: body['success'] == true && body['paid'] == true,
      amount: body['amount'],
      paid_amount: body['paid_amount'],
      installments: body['installments'],
      capture_method: body['capture_method']
    }
  end

  private

  def post(path, payload)
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request['X-Api-Key'] = self.class.api_key if self.class.api_key.present?
    request.body = payload.to_json

    response = http.request(request)
    parsed = begin
      JSON.parse(response.body.presence || '{}')
    rescue JSON::ParserError
      {}
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "InfinitePay #{path} HTTP #{response.code}: #{response.body.to_s.truncate(300)}"
    end

    parsed
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
    raise Error, "InfinitePay #{path} falhou: #{e.class}: #{e.message}"
  end
end
