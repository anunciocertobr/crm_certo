# Padrão por PÁGINA do Meta Lead Ads — pipelines, canais de notificação e
# dataset(s) sugeridos pro Conversion Leads que valem pra TODOS os
# formulários dessa página de uma vez, em vez de configurar formulário por
# formulário (ver MetaLeadForm, que é o nível de formulário).
#
# Pipelines e canais daqui se SOMAM com os do formulário (união, nunca
# sobrescrita) — ver Meta::LeadAds::ImportService#pipeline_targets_for e
# Meta::LeadAds::WhatsappNotifierService#resolve_destinations. Exceção: um
# MetaLeadForm com mode: 'notify_only' ignora os pipelines da página (a
# escolha explícita de não criar card vence a união).
class MetaLeadPageSetting < ApplicationRecord
  has_many :meta_lead_page_pipelines, dependent: :destroy
  accepts_nested_attributes_for :meta_lead_page_pipelines, allow_destroy: true

  validates :page_id, presence: true, uniqueness: true
end
