# Service to fetch Facebook post data from Graph API
# Uses Net::HTTP directly to avoid Koala issues with deprecated aggregated fields
require 'net/http'
require 'uri'
require 'json'

class Facebook::FetchPostDataService
  attr_reader :channel, :post_id

  def initialize(channel:, post_id:)
    @channel = channel
    @post_id = post_id
  end

  def perform
    return {} unless channel.is_a?(Channel::FacebookPage)
    return {} unless post_id.present?

    fetch_post_data
  rescue StandardError => e
    Rails.logger.error("Facebook::FetchPostDataService: Error fetching post data: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    {}
  end

  private

  def fetch_post_data
    # Use Net::HTTP directly to avoid Koala issues with deprecated aggregated fields
    # Using v3.2 API version - the error explicitly says deprecation is for "v3.3 and higher"
    # This version should not have the aggregated fields restriction
    # Using only basic fields without any .summary() or aggregated syntax

    # Use minimal fields to avoid any potential aggregated field interpretation
    # Removed 'story' and 'type' as they might be related to attachments
    basic_fields = 'id,message,created_time,permalink_url,from'
    Rails.logger.info("Facebook::FetchPostDataService: Fetching post data for #{post_id} with fields: #{basic_fields}")

    url = "https://graph.facebook.com/v26.0/#{post_id}"
    params = {
      fields: basic_fields,
      access_token: channel.page_access_token
    }

    uri = URI(url)
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    Rails.logger.info("Facebook::FetchPostDataService: Response status: #{response.code}")

    if response.code != '200'
      Rails.logger.error("Facebook::FetchPostDataService: HTTP error #{response.code}: #{response.body}")
      return {}
    end

    post_data = JSON.parse(response.body)

    if post_data['error']
      Rails.logger.error("Facebook::FetchPostDataService: Facebook API error: #{post_data['error']}")
      return {}
    end

    Rails.logger.info("Facebook::FetchPostDataService: Successfully fetched post data for #{post_id}")
    Rails.logger.info("Facebook::FetchPostDataService: Post data keys: #{post_data.keys.join(', ')}")
    Rails.logger.debug("Facebook::FetchPostDataService: Post data: #{post_data.inspect}")

    # Return normalized post data with string keys (for JSON compatibility)
    # Extract only the fields we need from the response
    result = {
      'id' => post_data['id'],
      'message' => post_data['message'],
      'created_time' => post_data['created_time'],
      'permalink_url' => post_data['permalink_url'],
      'from' => post_data['from']
    }.compact

    Rails.logger.info("Facebook::FetchPostDataService: Returning post data with keys: #{result.keys.join(', ')}")
    result
  rescue JSON::ParserError => e
    Rails.logger.error("Facebook::FetchPostDataService: Failed to parse JSON response: #{e.message}")
    {}
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error("Facebook::FetchPostDataService: Network timeout error: #{e.message}")
    {}
  rescue StandardError => e
    Rails.logger.error("Facebook::FetchPostDataService: Unexpected error: #{e.message}")
    Rails.logger.error("Facebook::FetchPostDataService: Post ID: #{post_id}")
    Rails.logger.error(e.backtrace.join("\n"))
    {}
  end

  # TODO: Add methods to fetch attachments and engagement metrics using Net::HTTP
  # when needed, to avoid Koala issues with deprecated aggregated fields
end

