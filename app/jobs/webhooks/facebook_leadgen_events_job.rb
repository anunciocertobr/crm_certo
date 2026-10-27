class Webhooks::FacebookLeadgenEventsJob < ApplicationJob
  queue_as :default

  def perform(value, page_id:)
    # A decisão entre persistir e virar card ou só notificar por WhatsApp
    # agora é por formulário (MetaLeadForm#mode), resolvida dentro do
    # próprio ImportService depois de buscar o lead na Graph API — ver
    # Meta::LeadAds::ImportService#import_from_webhook. Substitui o roteamento
    # antigo por lista global de page_id (Meta::LeadAds::NotifyOnlyService).
    Meta::LeadAds::ImportService.import_from_webhook(page_id: page_id, leadgen_id: value['leadgen_id'])
  end
end
