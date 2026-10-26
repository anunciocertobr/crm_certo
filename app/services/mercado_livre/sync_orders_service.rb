# Busca pedidos recentes do Mercado Livre (via #search_orders, não polling
# de evento como o iFood — a Orders API do ML não tem um endpoint de
# eventos pendentes equivalente, só busca por filtro) e grava/atualiza o
# espelho local (MercadoLivreOrder). Mesmo raciocínio de "não apagar dado
# já salvo com payload degradado" do Ifood::SyncOrdersService.
#
# #call testado contra a API real (26/10/2026) — devolveu {processed: 0}
# corretamente pra conta sem pedidos. #sync_order/#attributes_from (o
# mapeamento payload→MercadoLivreOrder) ainda SEM teste real — precisa de
# um pedido de verdade chegando pra confirmar os nomes de campo.
class MercadoLivre::SyncOrdersService
  def initialize(client: MercadoLivre::Client.new)
    @client = client
  end

  def call
    return { processed: 0 } unless @client.connected?

    result = @client.search_orders
    orders = result&.dig('results') || []
    orders.each { |o| sync_order(o['id']) }
    { processed: orders.size }
  end

  private

  def sync_order(ml_order_id)
    payload = @client.order_details(ml_order_id)
    return if payload.blank?

    order = MercadoLivreOrder.find_or_initialize_by(ml_order_id: ml_order_id.to_s)
    order.assign_attributes(attributes_from(order, payload))
    order.save!
  rescue MercadoLivre::Client::Error => e
    Rails.logger.error("Mercado Livre sync_order(#{ml_order_id}) failed: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("Mercado Livre sync_order(#{ml_order_id}) unexpected error: #{e.class} #{e.message}")
  end

  def attributes_from(order, payload)
    buyer = payload['buyer'] || {}
    status = payload['status']

    attrs = { raw_payload: payload }
    attrs[:customer_name] = [buyer['first_name'], buyer['last_name']].compact.join(' ').presence
    attrs[:items] = payload['order_items'].map { |i| item_attrs(i) } if payload['order_items'].present?
    attrs[:total_price] = payload['total_amount'].to_f if payload['total_amount'].present?
    attrs[:placed_at] = payload['date_created'] if payload['date_created'].present?
    attrs[:status] = status if status.present?
    attrs[:status] = 'confirmed' if order.new_record? && attrs[:status].blank?
    attrs.compact
  end

  def item_attrs(item)
    {
      'name' => item.dig('item', 'title'),
      'quantity' => item['quantity'],
      'unitPrice' => item['unit_price']
    }
  end
end
