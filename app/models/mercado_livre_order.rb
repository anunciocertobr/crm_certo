# Espelho local dos pedidos recebidos no Mercado Livre — mesmo raciocínio
# do IfoodOrder. STATUSES segue os valores reais de `order.status` da
# Orders API do ML (confirmed/payment_required/payment_in_process/
# partially_paid/paid/cancelled/invalid).
class MercadoLivreOrder < ApplicationRecord
  STATUSES = %w[confirmed payment_required payment_in_process partially_paid paid cancelled invalid].freeze

  validates :ml_order_id, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :total_price, numericality: { greater_than_or_equal_to: 0 }

  scope :order_by_recent, -> { order(placed_at: :desc, created_at: :desc) }

  def items_count
    items.to_a.sum { |item| item['quantity'].to_i }
  end
end
