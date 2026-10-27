# Um destino de Pipeline/Estágio do padrão de uma Página (ver
# MetaLeadPageSetting) — mesma forma de MetaLeadFormPipeline, só que no
# nível de página em vez de formulário.
class MetaLeadPagePipeline < ApplicationRecord
  belongs_to :meta_lead_page_setting
  belongs_to :pipeline
  belongs_to :pipeline_stage
end
