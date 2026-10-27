# Liga um formulário instantâneo do Meta (Lead Ads) ao CRM — o que falta pro
# webhook `leadgen` (Webhooks::FacebookController) saber o que fazer com cada
# lead que chega. `mode: 'pipeline'` (padrão) cria card/contato em 1+
# Pipeline/Estágio (meta_lead_form_pipelines); `mode: 'notify_only'` só manda
# a notificação de WhatsApp (ver Meta::LeadAds::WhatsappNotifierService), sem
# salvar nada no CRM — nesse modo não precisa de nenhum pipeline. Sem
# mapeamento nenhum, o lead fica retido em MetaLeadSubmission (status
# 'unmapped_form') até alguém mapear.
#
# `pipeline_id`/`pipeline_stage_id` são colunas legadas (de quando só dava
# pra apontar 1 pipeline) — mantidas nullable só pra não perder histórico de
# linhas antigas; todo código novo lê/escreve em meta_lead_form_pipelines.
class MetaLeadForm < ApplicationRecord
  MODES = %w[pipeline notify_only].freeze

  belongs_to :pipeline, optional: true
  belongs_to :pipeline_stage, optional: true
  has_many :meta_lead_submissions, dependent: :nullify
  has_many :meta_lead_form_pipelines, dependent: :destroy
  accepts_nested_attributes_for :meta_lead_form_pipelines, allow_destroy: true

  validates :page_id, presence: true
  validates :form_id, presence: true, uniqueness: true
  validates :mode, inclusion: { in: MODES }
  validate :pipeline_mode_requires_at_least_one_pipeline

  scope :active, -> { where(active: true) }

  private

  def pipeline_mode_requires_at_least_one_pipeline
    return unless mode == 'pipeline'
    return if meta_lead_form_pipelines.reject(&:marked_for_destruction?).any?

    errors.add(:base, 'Modo "Criar card no Pipeline" precisa de pelo menos um Pipeline/Estágio')
  end
end
