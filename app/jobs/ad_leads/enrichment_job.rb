# Preenche campaign/adset/ad name nos AdLead pendentes via Graph API.
# Ver AdLeads::EnrichmentService.

class AdLeads::EnrichmentJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    AdLeads::EnrichmentService.new.perform
  end
end
