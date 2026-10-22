# frozen_string_literal: true

# Um evento recebido no webhook de um Site — lead de formulário ou etapa de
# compra de e-commerce, vindos de uma tag do Google Tag Manager. Sem vínculo
# com Contact/PipelineItem nesta fase (ver Site, decisão de escopo) — só
# captura e exibe, igual MetaLeadSubmission começou antes de ganhar
# integração de pipeline.
class SiteLeadSubmission < ApplicationRecord
  belongs_to :site, optional: true
end
