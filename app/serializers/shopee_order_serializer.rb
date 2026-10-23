# frozen_string_literal: true

module ShopeeOrderSerializer
  extend self

  def serialize(order)
    {
      id: order.id,
      shopee_order_sn: order.shopee_order_sn,
      status: order.status,
      customer_name: order.customer_name,
      customer_phone: order.customer_phone,
      items: order.items || [],
      items_count: order.items_count,
      total_price: order.total_price.to_f,
      placed_at: order.placed_at&.iso8601,
      created_at: order.created_at&.iso8601,
      updated_at: order.updated_at&.iso8601
    }
  end

  def serialize_collection(orders)
    return [] unless orders

    orders.map { |order| serialize(order) }
  end
end
