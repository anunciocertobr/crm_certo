# Espelho local dos pedidos recebidos na Shopee — mesmo raciocínio do
# IfoodOrder/MercadoLivreOrder. STATUSES segue os valores reais de
# `order_status` da Shopee Order API (UNPAID/READY_TO_SHIP/PROCESSED/
# SHIPPED/COMPLETED/CANCELLED/INVOICE_PENDING).
class ShopeeOrder < ApplicationRecord
  STATUSES = %w[UNPAID READY_TO_SHIP PROCESSED SHIPPED COMPLETED CANCELLED INVOICE_PENDING].freeze

  validates :shopee_order_sn, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :total_price, numericality: { greater_than_or_equal_to: 0 }

  scope :order_by_recent, -> { order(placed_at: :desc, created_at: :desc) }

  def items_count
    items.to_a.sum { |item| item['quantity'].to_i }
  end
end
