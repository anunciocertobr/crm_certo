# Faz o polling de eventos do iFood, busca o detalhe de pedidos novos/alterados,
# grava/atualiza o espelho local (IfoodOrder) e confirma (acknowledge) os
# eventos processados — obrigatório no contrato da Order API para o iFood
# parar de reenviar o mesmo evento.
class Ifood::SyncOrdersService
  # code -> fullCode possíveis em eventos de pedido (nem todo evento é pedido;
  # eventos sem orderId, ex. de picking, são só confirmados e ignorados aqui).
  def initialize(client: Ifood::Client.new)
    @client = client
  end

  def call
    events = @client.poll_events
    return { processed: 0 } if events.blank?

    order_ids = events.filter_map { |e| e['orderId'] }.uniq
    order_ids.each { |id| sync_order(id) }

    @client.acknowledge(events.filter_map { |e| e['id'] })
    { processed: order_ids.size }
  end

  private

  def sync_order(ifood_order_id)
    payload = @client.order_details(ifood_order_id)
    return if payload.blank?

    order = IfoodOrder.find_or_initialize_by(ifood_order_id: ifood_order_id)
    order.assign_attributes(attributes_from(order, payload))
    order.save!
  rescue Ifood::Client::Error => e
    Rails.logger.error("iFood sync_order(#{ifood_order_id}) failed: #{e.message}")
  rescue StandardError => e
    # Um payload inesperado (ex.: campo com formato diferente do documentado)
    # não pode derrubar o #call inteiro — isso pararia de confirmar (acknowledge)
    # até os eventos de OUTROS pedidos que processaram bem, e o polling roda a
    # cada minuto via Ifood::PollEventsJob: um erro silencioso aqui vira uma
    # falha recorrente que o iFood pode interpretar como loja desconectada.
    Rails.logger.error("iFood sync_order(#{ifood_order_id}) unexpected error: #{e.class} #{e.message}")
  end

  # GET order_details às vezes devolve um payload degradado (ex.: pedido de
  # teste já cancelado/concluído), quase só com "id" e nada mais — um GET
  # tardio desses não pode apagar dado real já salvo nem reverter uma ação
  # que a gente acabou de confirmar com o iFood (ex.: cancelar). Por isso só
  # grava cada campo quando o payload realmente traz um valor pra ele;
  # campo ausente = mantém o que já está salvo, não vira nil/0/'PLACED'.
  def attributes_from(order, payload)
    customer = payload['customer'] || {}
    total = payload.dig('total', 'orderAmount') || payload.dig('total', 'value')
    incoming_status = payload['orderStatus'] || payload['status']

    attrs = { raw_payload: payload }
    attrs[:display_id] = payload['displayId'] if payload['displayId'].present?
    attrs[:order_type] = payload['orderType'] if payload['orderType'].present?
    attrs[:customer_name] = customer['name'] if customer['name'].present?
    attrs[:customer_phone] = customer.dig('phone', 'number') if customer.dig('phone', 'number').present?
    attrs[:items] = payload['items'].map { |i| item_attrs(i) } if payload['items'].present?
    attrs[:total_price] = total.to_f if total.present?
    attrs[:placed_at] = payload['createdAt'] if payload['createdAt'].present?
    attrs[:status] = incoming_status if incoming_status.present?
    attrs[:status] = 'PLACED' if order.new_record? && attrs[:status].blank?
    attrs
  end

  # unitPrice vem ora como número direto (ex.: pedidos de teste/homologação),
  # ora como objeto {value, currency} (documentado) — trata os dois formatos
  # sem quebrar (Float#dig não existe, então chamar .dig direto derrubava o
  # sync inteiro sempre que um pedido vinha no formato numérico).
  def item_attrs(item)
    unit_price = item['unitPrice']
    unit_price = unit_price['value'] if unit_price.is_a?(Hash)

    {
      'name' => item['name'],
      'quantity' => item['quantity'],
      'unitPrice' => unit_price
    }
  end
end
