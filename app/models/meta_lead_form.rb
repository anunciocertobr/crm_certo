# Liga um formulário instantâneo do Meta (Lead Ads) a um Pipeline/Estágio do
# CRM — o que falta pro webhook `leadgen` (Webhooks::FacebookController)
# saber pra onde mandar cada lead que chega. Sem mapeamento, o lead fica
# retido em MetaLeadSubmission (status 'unmapped_form') até alguém mapear.
class MetaLeadForm < ApplicationRecord
  belongs_to :pipeline
  belongs_to :pipeline_stage
  has_many :meta_lead_submissions, dependent: :nullify

  validates :page_id, presence: true
  validates :form_id, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
end
