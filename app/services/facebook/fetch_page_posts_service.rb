# Service to fetch Facebook page posts from Graph API
# Uses Net::HTTP directly to avoid Koala issues with deprecated aggregated fields
require 'net/http'
require 'uri'
require 'json'

class Facebook::FetchPagePostsService
  attr_reader :channel, :limit

  def initialize(channel:, limit: 25)
    @channel = channel
    @limit = limit
  end

  def perform
    return [] unless channel.is_a?(Channel::FacebookPage)
    return [] unless channel.page_id.present?
    return [] unless channel.page_access_token.present?

    fetch_page_posts
  rescue StandardError => e
    Rails.logger.error("Facebook::FetchPagePostsService: Error fetching page posts: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    []
  end

  private

  def fetch_page_posts
    # Fetch posts from Facebook Graph API
    # Using v3.2 API version to avoid deprecation issues
    basic_fields = 'id,message,created_time,permalink_url,from'
    Rails.logger.info("Facebook::FetchPagePostsService: Fetching posts for page #{channel.page_id} with fields: #{basic_fields}")

    url = "https://graph.facebook.com/v26.0/#{channel.page_id}/posts"
    params = {
      fields: basic_fields,
      access_token: channel.page_access_token,
      limit: limit
    }

    uri = URI(url)
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    Rails.logger.info("Facebook::FetchPagePostsService: Response status: #{response.code}")

    if response.code != '200'
      Rails.logger.error("Facebook::FetchPagePostsService: HTTP error #{response.code}: #{response.body}")
      return []
    end

    result = JSON.parse(response.body)

    if result['error']
      Rails.logger.error("Facebook::FetchPagePostsService: Facebook API error: #{result['error']}")
      return []
    end

    posts = result['data'] || []
    Rails.logger.info("Facebook::FetchPagePostsService: Successfully fetched #{posts.length} posts")

    # Return normalized posts with string keys
    posts.map do |post|
      {
        'id' => post['id'],
        'message' => post['message']&.truncate(100),
        'created_time' => post['created_time'],
        'permalink_url' => post['permalink_url'],
        'from' => post['from']
      }.compact
    end
  rescue JSON::ParserError => e
    Rails.logger.error("Facebook::FetchPagePostsService: Failed to parse JSON response: #{e.message}")
    []
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error("Facebook::FetchPagePostsService: Network timeout error: #{e.message}")
    []
  rescue StandardError => e
    Rails.logger.error("Facebook::FetchPagePostsService: Unexpected error: #{e.message}")
    Rails.logger.error("Facebook::FetchPagePostsService: Page ID: #{channel.page_id}")
    Rails.logger.error(e.backtrace.join("\n"))
    []
  end
end

