# Busca pedidos recentes da Shopee (#order_list numa janela de tempo, igual
# a estratégia do Mercado Livre — a Shopee também não expõe um polling de
# evento como o iFood) e grava/atualiza o espelho local (ShopeeOrder).
#
# NUNCA TESTADO CONTRA A API REAL — ver nota em Shopee::Client.
class Shopee::SyncOrdersService
  # Janela padrão de 7 dias pra trás — a Shopee limita cada busca a no
  # máximo 15 dias de intervalo (time_from/time_to), então janelas maiores
  # precisariam paginar por período, não só por cursor.
  def initialize(client: Shopee::Client.new, window: 7.days)
    @client = client
    @window = window
  end

  def call
    return { processed: 0 } unless @client.connected?

    result = @client.order_list(time_from: @window.ago, time_to: Time.current)
    order_sns = result&.dig('response', 'order_list')&.map { |o| o['order_sn'] } || []
    return { processed: 0 } if order_sns.empty?

    details = @client.order_detail(order_sns)
    (details&.dig('response', 'order_list') || []).each { |payload| sync_order(payload) }
    { processed: order_sns.size }
  end

  private

  def sync_order(payload)
    order_sn = payload['order_sn']
    return if order_sn.blank?

    order = ShopeeOrder.find_or_initialize_by(shopee_order_sn: order_sn)
    order.assign_attributes(attributes_from(order, payload))
    order.save!
  rescue Shopee::Client::Error => e
    Rails.logger.error("Shopee sync_order(#{order_sn}) failed: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("Shopee sync_order(#{order_sn}) unexpected error: #{e.class} #{e.message}")
  end

  def attributes_from(order, payload)
    recipient = payload['recipient_address'] || {}
    status = payload['order_status']

    attrs = { raw_payload: payload }
    attrs[:customer_name] = recipient['name'] if recipient['name'].present?
    attrs[:customer_phone] = recipient['phone'] if recipient['phone'].present?
    attrs[:items] = payload['item_list'].map { |i| item_attrs(i) } if payload['item_list'].present?
    attrs[:total_price] = payload['total_amount'].to_f if payload['total_amount'].present?
    attrs[:placed_at] = Time.zone.at(payload['create_time']) if payload['create_time'].present?
    attrs[:status] = status if status.present?
    attrs[:status] = 'UNPAID' if order.new_record? && attrs[:status].blank?
    attrs.compact
  end

  def item_attrs(item)
    {
      'name' => item['item_name'],
      'quantity' => item['model_quantity_purchased'],
      'unitPrice' => item['model_discounted_price'] || item['model_original_price']
    }
  end
end
