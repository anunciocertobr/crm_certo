# Um destino de Pipeline/Estágio de um MetaLeadForm — existe mais de uma
# linha por formulário quando o lead deve virar card em mais de um Pipeline
# ao mesmo tempo (ver MetaLeadForm#mode e Meta::LeadAds::ImportService#process).
class MetaLeadFormPipeline < ApplicationRecord
  belongs_to :meta_lead_form
  belongs_to :pipeline
  belongs_to :pipeline_stage
end
