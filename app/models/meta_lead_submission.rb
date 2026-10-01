# Um lead bruto recebido do webhook `leadgen` do Meta — persistido mesmo
# quando o formulário ainda não tem mapeamento (status 'unmapped_form') ou
# quando algo falha (status 'error'), pra nenhum lead sumir silenciosamente
# enquanto a agência não configura o MetaLeadForm correspondente.
class MetaLeadSubmission < ApplicationRecord
  STATUSES = %w[unmapped_form processed error].freeze

  belongs_to :meta_lead_form, optional: true
  belongs_to :contact, optional: true
  belongs_to :pipeline_item, optional: true

  validates :leadgen_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
end
