# frozen_string_literal: true

# Pagamento online do cardápio digital. Ligado em Organização > Cardápio
# Digital (MENU_CHECKOUT_ENABLED), com o provedor escolhido em
# MENU_CHECKOUT_PROVIDER: 'infinitepay' (padrão) ou 'mercadopago'.
#
# Fluxo:
#   1. #start — o checkout público manda o pedido; os preços são recalculados
#      AQUI a partir do Product (nunca confiamos no preço vindo do navegador),
#      o pedido fica guardado no Redis sob o `order_token` (que vai pro
#      provedor como order_nsu / external_reference) e devolvemos a URL de
#      pagamento do provedor.
#   2. O cliente paga. O provedor avisa pelo webhook e/ou o cliente volta pela
#      redirect_url — os dois caminhos chamam #confirm_infinitepay ou
#      #confirm_mercadopago.
#   3. A confirmação SEMPRE consulta o provedor (o corpo do webhook nunca é
#      tratado como prova de pagamento) e, só na primeira confirmação,
#      enfileira o envio da mensagem "Pedido PAGO" pro WhatsApp da loja.
class DigitalMenu::CheckoutService
  ORDER_TTL = 7.days
  ORDER_KEY = 'digital_menu_checkout_order:%s'
  NOTIFIED_KEY = 'digital_menu_checkout_notified:%s'
  STATUS_KEY = 'digital_menu_order_status:%s'

  PROVIDERS = {
    'infinitepay' => 'DigitalMenu::InfinitePayClient',
    'mercadopago' => 'DigitalMenu::MercadoPagoClient'
  }.freeze

  class InvalidOrder < StandardError; end

  Result = Struct.new(:status, :checkout_url, :error, keyword_init: true)

  def self.provider_key
    key = GlobalConfigService.load('MENU_CHECKOUT_PROVIDER', nil).to_s.strip.downcase
    PROVIDERS.key?(key) ? key : 'infinitepay'
  end

  def self.provider_client(key = provider_key)
    PROVIDERS.fetch(key).constantize
  end

  # Checkout ligado E com o provedor escolhido configurado.
  def self.enabled?
    flag = GlobalConfigService.load('MENU_CHECKOUT_ENABLED', nil)
    ActiveModel::Type::Boolean.new.cast(flag) == true && provider_client.configured?
  end

  def self.load_order(token)
    return nil if token.blank?

    raw = Redis::Alfred.get(format(ORDER_KEY, token))
    raw.present? ? JSON.parse(raw).deep_symbolize_keys : nil
  end

  # customer: hash do formulário; items: [{ product_id:, quantity: }]
  def start(order_token:, customer:, items:, notes:)
    provider = self.class.provider_key
    priced_items = price_items(items)
    order = {
      token: order_token,
      provider: provider,
      customer: customer,
      items: priced_items,
      notes: notes,
      created_at: Time.current.iso8601
    }
    Redis::Alfred.setex(format(ORDER_KEY, order_token), order.to_json, ORDER_TTL)

    url = self.class.provider_client(provider).new.create_link(
      order_nsu: order_token,
      items: priced_items.map do |i|
        { description: i[:name].to_s.truncate(120), quantity: i[:quantity], price: i[:price_cents] }
      end,
      redirect_url: redirect_url(order_token),
      webhook_url: webhook_url(provider),
      customer: customer
    )
    Redis::Alfred.setex(format(STATUS_KEY, order_token), 'awaiting_payment', ORDER_TTL)
    Result.new(status: 'awaiting_payment', checkout_url: url)
  end

  # InfinitePay: webhook traz order_nsu/transaction_nsu/invoice_slug; o retorno
  # do cliente traz os mesmos dados na URL. payment_hint (receipt_url etc.)
  # só enriquece a mensagem — quem decide "pago" é o /payment_check.
  def confirm_infinitepay(order_token:, transaction_nsu:, slug:, payment_hint: {})
    order = self.class.load_order(order_token)
    return Result.new(status: 'not_found') unless order
    return Result.new(status: 'not_paid') if transaction_nsu.blank? || slug.blank?

    check = DigitalMenu::InfinitePayClient.new.payment_check(
      order_nsu: order_token, transaction_nsu: transaction_nsu, slug: slug
    )
    return Result.new(status: 'not_paid') unless check[:paid]

    mark_paid(order_token, order, {
      provider: DigitalMenu::InfinitePayClient.label,
      capture_method: check[:capture_method] || payment_hint[:capture_method],
      installments: check[:installments] || payment_hint[:installments],
      amount_cents: check[:amount],
      paid_amount_cents: check[:paid_amount],
      transaction_nsu: transaction_nsu,
      receipt_url: payment_hint[:receipt_url]
    })
  end

  # Mercado Pago: webhook e retorno do cliente só trazem o payment_id; o
  # pedido é achado pelo external_reference do pagamento consultado na API.
  # `order_token` (quando vem do retorno do cliente) tem que bater com ele.
  def confirm_mercadopago(payment_id:, order_token: nil)
    return Result.new(status: 'not_paid') if payment_id.blank?

    payment = DigitalMenu::MercadoPagoClient.new.payment(payment_id)
    token = payment[:external_reference].to_s
    return Result.new(status: 'not_found') if order_token.present? && token != order_token

    order = self.class.load_order(token)
    return Result.new(status: 'not_found') unless order
    return Result.new(status: payment[:status] == 'pending' || payment[:status] == 'in_process' ? 'awaiting_payment' : 'not_paid') unless payment[:paid]

    mark_paid(token, order, {
      provider: DigitalMenu::MercadoPagoClient.label,
      capture_method: payment[:capture_method],
      installments: payment[:installments],
      amount_cents: payment[:amount],
      paid_amount_cents: payment[:paid_amount],
      transaction_nsu: payment[:transaction_id]
    })
  end

  private

  def mark_paid(token, order, payment_info)
    first_time = Redis::Alfred.set(format(NOTIFIED_KEY, token), '1', nx: true, ex: ORDER_TTL.to_i)
    return Result.new(status: current_status(token)) unless first_time

    Redis::Alfred.setex(format(STATUS_KEY, token), 'paid', ORDER_TTL)
    DigitalMenu::SendOrderNotificationJob.perform_later(
      order_token: token,
      customer: order[:customer],
      items: order[:items].map { |i| { name: i[:name], price: i[:price_cents] / 100.0, quantity: i[:quantity] } },
      payment_method: payment_info[:provider],
      notes: order[:notes].to_s,
      payment: payment_info.compact
    )
    Result.new(status: 'paid')
  end

  def current_status(token)
    Redis::Alfred.get(format(STATUS_KEY, token)) || 'paid'
  end

  def price_items(items)
    raise InvalidOrder, 'Pedido sem itens' if items.blank?

    items.map do |item|
      product = Product.active.sellable.find_by(id: item[:product_id])
      raise InvalidOrder, "Produto indisponível: #{item[:product_id]}" unless product

      quantity = item[:quantity].to_i
      raise InvalidOrder, 'Quantidade inválida' unless quantity.between?(1, 999)

      price_cents = (product.default_price.to_d * 100).round.to_i
      raise InvalidOrder, "Produto sem preço: #{product.name}" unless price_cents.positive?

      { product_id: product.id, name: product.name, quantity: quantity, price_cents: price_cents }
    end
  end

  def redirect_url(token)
    base = ENV.fetch('FRONTEND_URL', '').chomp('/')
    "#{base}/cardapio-digital?pedido=#{CGI.escape(token)}"
  end

  def webhook_url(provider)
    base = ENV.fetch('BACKEND_URL', ENV.fetch('FRONTEND_URL', '')).chomp('/')
    "#{base}/public/api/v1/menu/orders/#{provider}_webhook"
  end
end
