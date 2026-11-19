# frozen_string_literal: true

# Executa DigitalMenu::OrderNotificationService em background — o envio real
# (ContactInboxWithContactBuilder/ConversationBuilder/mensagem) pode demorar
# ou travar numa chamada de rede pro provider de WhatsApp, e isso nunca pode
# prender a resposta do checkout público. Grava o resultado (sent/failed) no
# Redis sob `order_token`, pra que o checkout público consiga consultar via
# polling e, se falhar, oferecer o fallback "enviar você mesmo pelo WhatsApp".
#
# `payment` vem preenchido só quando o pedido foi pago online pelo checkout
# da InfinitePay (ver DigitalMenu::CheckoutService) — aí a mensagem sai como
# "Pedido PAGO" com os dados do pagamento. Nesse caso uma falha no envio é
# re-levantada pra o Sidekiq tentar de novo: o cliente já pagou e a loja não
# pode ficar sem saber do pedido.
class DigitalMenu::SendOrderNotificationJob < ApplicationJob
  queue_as :default

  STATUS_TTL = 10.minutes

  class PaidOrderNotificationFailed < StandardError; end

  def perform(order_token:, customer:, items:, payment_method:, notes:, payment: nil)
    result = DigitalMenu::OrderNotificationService.new(
      customer: customer,
      items: items,
      payment_method: payment_method,
      notes: notes,
      payment: payment
    ).call

    write_status(order_token, result.success ? 'sent' : 'failed', paid: payment.present?)
    raise PaidOrderNotificationFailed, "pedido pago #{order_token}: #{result.error}" if payment.present? && !result.success
  rescue PaidOrderNotificationFailed
    raise
  rescue StandardError => e
    write_status(order_token, 'failed', paid: payment.present?)
    raise e
  end

  private

  def write_status(order_token, status, paid: false)
    ttl = paid ? DigitalMenu::CheckoutService::ORDER_TTL : STATUS_TTL
    Redis::Alfred.setex("digital_menu_order_status:#{order_token}", status, ttl)
  end
end
