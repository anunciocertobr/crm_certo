# frozen_string_literal: true

# Pagamento online do cardápio digital via Checkout Integrado da InfinitePay.
# Ligado em Organização > Cardápio Digital (MENU_CHECKOUT_ENABLED).
#
# Fluxo:
#   1. #start — o checkout público manda o pedido; os preços são recalculados
#      AQUI a partir do Product (nunca confiamos no preço vindo do navegador),
#      o pedido fica guardado no Redis sob o `order_token` (que também é o
#      `order_nsu` na InfinitePay) e devolvemos a URL de pagamento.
#   2. O cliente paga. A InfinitePay avisa pelo webhook e/ou o cliente volta
#      pela redirect_url — os dois caminhos chamam #confirm.
#   3. #confirm confirma no /payment_check (o webhook não tem assinatura, então
#      nunca acreditamos só no corpo dele) e, só na primeira confirmação,
#      enfileira o envio da mensagem "Pedido PAGO" pro WhatsApp da loja.
class DigitalMenu::CheckoutService
  ORDER_TTL = 7.days
  ORDER_KEY = 'digital_menu_checkout_order:%s'
  NOTIFIED_KEY = 'digital_menu_checkout_notified:%s'
  STATUS_KEY = 'digital_menu_order_status:%s'

  class InvalidOrder < StandardError; end

  Result = Struct.new(:status, :checkout_url, :error, keyword_init: true)

  def self.load_order(token)
    raw = Redis::Alfred.get(format(ORDER_KEY, token))
    raw.present? ? JSON.parse(raw).deep_symbolize_keys : nil
  end

  # customer: hash do formulário; items: [{ product_id:, quantity: }]
  def start(order_token:, customer:, items:, notes:)
    priced_items = price_items(items)
    order = {
      token: order_token,
      customer: customer,
      items: priced_items,
      notes: notes,
      created_at: Time.current.iso8601
    }
    Redis::Alfred.setex(format(ORDER_KEY, order_token), order.to_json, ORDER_TTL)

    url = DigitalMenu::InfinitePayClient.new.create_link(
      order_nsu: order_token,
      items: priced_items.map do |i|
        { description: i[:name].to_s.truncate(120), quantity: i[:quantity], price: i[:price_cents] }
      end,
      redirect_url: redirect_url(order_token),
      webhook_url: webhook_url,
      customer: infinitepay_customer(customer),
      address: infinitepay_address(customer)
    )
    Redis::Alfred.setex(format(STATUS_KEY, order_token), 'awaiting_payment', ORDER_TTL)
    Result.new(status: 'awaiting_payment', checkout_url: url)
  end

  # Idempotente: pode ser chamado pelo webhook e pelo retorno do cliente,
  # quantas vezes for — a mensagem só é enfileirada uma vez.
  # payment_hint: dados vindos do webhook/redirect (receipt_url etc.), usados
  # só pra enriquecer a mensagem; a decisão de "pago" vem do /payment_check.
  def confirm(order_token:, transaction_nsu:, slug:, payment_hint: {})
    order = self.class.load_order(order_token)
    return Result.new(status: 'not_found') unless order
    return Result.new(status: 'not_paid') if transaction_nsu.blank? || slug.blank?

    check = DigitalMenu::InfinitePayClient.new.payment_check(
      order_nsu: order_token, transaction_nsu: transaction_nsu, slug: slug
    )
    return Result.new(status: 'not_paid') unless check[:paid]

    first_time = Redis::Alfred.set(format(NOTIFIED_KEY, order_token), '1', nx: true, ex: ORDER_TTL.to_i)
    return Result.new(status: current_status(order_token)) unless first_time

    Redis::Alfred.setex(format(STATUS_KEY, order_token), 'paid', ORDER_TTL)
    DigitalMenu::SendOrderNotificationJob.perform_later(
      order_token: order_token,
      customer: order[:customer],
      items: order[:items].map { |i| { name: i[:name], price: i[:price_cents] / 100.0, quantity: i[:quantity] } },
      payment_method: 'InfinitePay',
      notes: order[:notes].to_s,
      payment: {
        capture_method: check[:capture_method] || payment_hint[:capture_method],
        installments: check[:installments] || payment_hint[:installments],
        amount_cents: check[:amount],
        paid_amount_cents: check[:paid_amount],
        transaction_nsu: transaction_nsu,
        receipt_url: payment_hint[:receipt_url]
      }.compact
    )
    Result.new(status: 'paid')
  end

  private

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

  def webhook_url
    base = ENV.fetch('BACKEND_URL', ENV.fetch('FRONTEND_URL', '')).chomp('/')
    "#{base}/public/api/v1/menu/orders/infinitepay_webhook"
  end

  def infinitepay_customer(customer)
    phone = customer[:phone].to_s.gsub(/\D/, '')
    phone = "55#{phone}" if phone.present? && !phone.start_with?('55')
    {
      name: customer[:full_name].presence,
      email: customer[:email].presence,
      phone_number: phone.present? ? "+#{phone}" : nil
    }.compact.presence
  end

  def infinitepay_address(customer)
    cep = customer[:zip].to_s.gsub(/\D/, '')
    return nil if cep.length != 8 || customer[:address].blank?

    {
      cep: cep,
      street: customer[:address],
      number: customer[:number].presence,
      neighborhood: customer[:neighborhood].presence,
      city: customer[:city].presence,
      state: customer[:state].presence
    }.compact
  end
end
