module Integrations
  module HelenaWts
    class ContactsService
      def initialize(client: BaseClient.new)
        @client = client
      end

      def list(page: 1, limit: 100)
        resp = @client.get("/core/v1/contact", { page: page, limit: limit })
        body = resp.parsed_response || {}
        items = body.is_a?(Hash) ? (body["items"] || body["data"] || []) : Array(body)
        { items: items, raw: body, code: resp.code }
      rescue => e
        Rails.logger.error("[HelenaWts] list failed: #{e.message}")
        raise
      end

      def fetch_all(limit: 100)
        page = 1
        result_items = []
        loop do
          result = list(page: page, limit: limit)
          items = result[:items] || []
          break if items.blank?
          result_items.concat(items)
          break if items.size < limit
          page += 1
        end
        result_items
      end
    end
  end
end
