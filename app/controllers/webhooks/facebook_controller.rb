class Webhooks::FacebookController < ActionController::API
  # This controller handles page object changes from the Facebook webhook —
  # feed (posts/comments) and leadgen (Lead Ads instant forms). The gem
  # facebook-messenger handles messaging events via /bot route separately.
  # Both fields arrive on the same callback URL/payload, already verified
  # once in the App's Webhooks product — no GET hub.challenge handler needed
  # here, subscribing a new field to an existing verified URL doesn't
  # re-trigger verification.

  def feed_events
    Rails.logger.info('Facebook page webhook received')

    # Payload structure: { "object": "page", "entry": [{ "id": "PAGE_ID", "changes": [...] }] }
    if params['object'].casecmp('page').zero? && params['entry'].present?
      process_page_changes(params['entry'])
      render json: { status: 'received' }
    else
      Rails.logger.warn("Facebook page webhook: Invalid payload structure - object: #{params['object']}")
      head :unprocessable_entity
    end
  end

  private

  def process_page_changes(entries)
    entries.each do |entry|
      page_id = entry['id']
      changes = entry['changes'] || []

      next if changes.empty?

      Rails.logger.info("Processing #{changes.length} page changes for page #{page_id}")

      changes.each do |change|
        case change['field']
        when 'feed'
          Webhooks::FacebookFeedEventsJob.perform_later(change['value'], page_id: page_id)
        when 'leadgen'
          Webhooks::FacebookLeadgenEventsJob.perform_later(change['value'], page_id: page_id)
        end
      end
    end
  end
end

