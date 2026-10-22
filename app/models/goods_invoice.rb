# NF-e 55 (mercadoria/e-commerce) ou NFC-e 65 (balcão/delivery). Mesma
# forma geral do ServiceInvoice (NFS-e), mas deliberadamente um model
# separado — âmbito estadual (SEFAZ) e campos fiscais diferentes
# (ICMS/NCM/CFOP vs ISS/item de serviço).
class GoodsInvoice < ApplicationRecord
  STATUSES = %w[pending processing authorized error cancelled].freeze
  MODELOS = %w[55 65].freeze

  belongs_to :goods_fiscal_profile
  belongs_to :work_order, optional: true

  validates :modelo, inclusion: { in: MODELOS }
  validates :numero, :serie, :natureza_operacao, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :numero, uniqueness: { scope: %i[goods_fiscal_profile_id serie modelo] }
  validates :valor_produtos, :valor_total, numericality: { greater_than_or_equal_to: 0 }
  validate :itens_presentes

  scope :pending, -> { where(status: 'pending') }

  def authorized?
    status == 'authorized'
  end

  def nfce?
    modelo == '65'
  end

  private

  def itens_presentes
    errors.add(:itens, 'precisa ter ao menos um item') if itens.blank?
  end
end
