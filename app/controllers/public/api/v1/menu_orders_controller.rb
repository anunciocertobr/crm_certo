# frozen_string_literal: true

# Anonymous, public order submission from the digital menu checkout — enqueues
# DigitalMenu::SendOrderNotificationJob to deliver the order to the store's
# WhatsApp using whatever channel/number is configured in Organização >
# Cardápio Digital. Always 200s immediately for the customer: the actual send
# runs in background, so neither a slow/hanging provider call nor a missing
# configuration ever blocks the checkout response. The response carries an
# `order_token` the frontend polls via #status to know if the background send
# actually succeeded — used to show a "send it yourself via WhatsApp" fallback
# (with the order pre-filled) only when the automated send really failed.
#
# Pagamento online (MENU_CHECKOUT_ENABLED): quando ligado, #create NÃO envia o
# pedido pro WhatsApp — cria um link de pagamento no provedor escolhido
# (InfinitePay ou Mercado Pago) e devolve `checkout_url`. A mensagem "Pedido
# PAGO" só sai depois que o pagamento é confirmado pelo webhook do provedor ou
# por #confirm_payment (ver DigitalMenu::CheckoutService).
class Public::Api::V1::MenuOrdersController < PublicController
  def create
    order_token = params[:order_token].presence || SecureRandom.uuid
    return create_with_checkout(order_token) if DigitalMenu::CheckoutService.enabled?

    Redis::Alfred.setex("digital_menu_order_status:#{order_token}", 'pending', DigitalMenu::SendOrderNotificationJob::STATUS_TTL)

    DigitalMenu::SendOrderNotificationJob.perform_later(
      order_token: order_token,
      customer: customer_params,
      items: items_params,
      payment_method: params[:payment_method].to_s,
      notes: params[:notes].to_s
    )

    render json: { success: true, order_token: order_token }
  end

  # GET /public/api/v1/menu/orders/:token/status
  def status
    status = Redis::Alfred.get("digital_menu_order_status:#{params[:token]}") || 'pending'
    render json: { success: true, status: status }
  end

  # POST /public/api/v1/menu/orders/:token/confirm_payment
  # Chamado pelo cardápio quando o cliente volta do checkout. Caminho de
  # reserva caso o webhook atrase/falhe. Mercado Pago devolve payment_id
  # (ou collection_id); InfinitePay devolve transaction_nsu + slug.
  def confirm_payment
    service = DigitalMenu::CheckoutService.new
    mp_payment_id = (params[:payment_id].presence || params[:collection_id]).to_s
    result = if mp_payment_id.present? && mp_payment_id != 'null'
               service.confirm_mercadopago(payment_id: mp_payment_id, order_token: params[:token].to_s)
             else
               service.confirm_infinitepay(
                 order_token: params[:token].to_s,
                 transaction_nsu: params[:transaction_nsu].to_s,
                 slug: params[:slug].to_s,
                 payment_hint: payment_hint(params)
               )
             end
    render json: { success: true, status: result.status }
  rescue DigitalMenu::CheckoutProviderError => e
    Rails.logger.error("[DigitalMenu checkout] confirm_payment #{params[:token]}: #{e.message}")
    render json: { success: false, status: 'check_failed' }
  end

  # POST /public/api/v1/menu/orders/infinitepay_webhook
  # Corpo: { invoice_slug, amount, paid_amount, installments, capture_method,
  #          transaction_nsu, order_nsu, receipt_url, items }
  # O webhook não tem assinatura — por isso confirmamos no /payment_check
  # antes de considerar pago. 200 = processado/ignorado; 400 = falha
  # temporária, a InfinitePay reenvia.
  def infinitepay_webhook
    result = DigitalMenu::CheckoutService.new.confirm_infinitepay(
      order_token: params[:order_nsu].to_s,
      transaction_nsu: params[:transaction_nsu].to_s,
      slug: (params[:invoice_slug].presence || params[:slug]).to_s,
      payment_hint: payment_hint(params)
    )
    Rails.logger.info("[DigitalMenu checkout] infinitepay webhook order=#{params[:order_nsu]} status=#{result.status}")
    head :ok
  rescue DigitalMenu::CheckoutProviderError => e
    Rails.logger.error("[DigitalMenu checkout] infinitepay webhook order=#{params[:order_nsu]}: #{e.message}")
    head :bad_request
  end

  # POST /public/api/v1/menu/orders/mercadopago_webhook
  # Webhook: { type: "payment", data: { id } } (também vem em ?type=payment&data.id=)
  # IPN antigo: ?topic=payment&id=. Outros tópicos (merchant_order etc.) são
  # ignorados com 200. O status é sempre consultado em GET /v1/payments/:id.
  # Fora de 200/201 o Mercado Pago reenvia.
  def mercadopago_webhook
    kind = (params[:type].presence || params[:topic]).to_s
    payment_id = (params.dig(:data, :id).presence || params['data.id'].presence || params[:id]).to_s
    return head(:ok) unless kind == 'payment' && payment_id.present?

    result = DigitalMenu::CheckoutService.new.confirm_mercadopago(payment_id: payment_id)
    Rails.logger.info("[DigitalMenu checkout] mercadopago webhook payment=#{payment_id} status=#{result.status}")
    head :ok
  rescue DigitalMenu::CheckoutProviderError => e
    Rails.logger.error("[DigitalMenu checkout] mercadopago webhook payment=#{payment_id}: #{e.message}")
    head :bad_gateway
  end

  private

  def create_with_checkout(order_token)
    result = DigitalMenu::CheckoutService.new.start(
      order_token: order_token,
      customer: customer_params,
      items: checkout_items_params,
      notes: params[:notes].to_s
    )
    render json: { success: true, order_token: order_token, checkout_url: result.checkout_url }
  rescue DigitalMenu::CheckoutService::InvalidOrder => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue DigitalMenu::CheckoutProviderError => e
    Rails.logger.error("[DigitalMenu checkout] create_link #{order_token}: #{e.message}")
    render json: { success: false, error: 'Não foi possível gerar o pagamento. Tente novamente.' }, status: :bad_gateway
  end

  def payment_hint(source)
    {
      receipt_url: source[:receipt_url].presence,
      capture_method: source[:capture_method].presence,
      installments: source[:installments].presence
    }.compact
  end

  def customer_params
    params.require(:customer)
          .permit(:full_name, :cpf, :birth_date, :gender, :phone, :instagram, :email,
                  :zip, :address, :number, :neighborhood, :city, :state)
          .to_h.symbolize_keys
  end

  def items_params
    params.require(:items).map do |item|
      item.permit(:name, :price, :quantity).to_h.symbolize_keys
    end
  end

  def checkout_items_params
    params.require(:items).map do |item|
      item.permit(:product_id, :quantity).to_h.symbolize_keys
    end
  end
end
