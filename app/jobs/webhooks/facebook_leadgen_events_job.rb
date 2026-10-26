class Webhooks::FacebookLeadgenEventsJob < ApplicationJob
  queue_as :default

  def perform(value, page_id:)
    leadgen_id = value['leadgen_id']

    if Meta::LeadAds::NotifyOnlyService.enabled_for?(page_id)
      Meta::LeadAds::NotifyOnlyService.call(page_id: page_id, leadgen_id: leadgen_id)
    else
      Meta::LeadAds::ImportService.import_from_webhook(page_id: page_id, leadgen_id: leadgen_id)
    end
  end
end
