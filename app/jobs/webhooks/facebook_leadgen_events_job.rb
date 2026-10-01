class Webhooks::FacebookLeadgenEventsJob < ApplicationJob
  queue_as :default

  def perform(value, page_id:)
    Meta::LeadAds::ImportService.import_from_webhook(page_id: page_id, leadgen_id: value['leadgen_id'])
  end
end
