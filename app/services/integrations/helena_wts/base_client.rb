module Integrations
  module HelenaWts
    class BaseClient
      include HTTParty

      base_uri "https://api.wts.chat"

      def initialize(token: nil)
        @token = token || ENV["HELENA_WTS_TOKEN"] || Rails.application.credentials.dig(:helena_wts, :token)
        raise "Helena/WTS token missing" if @token.blank?
      end

      def get(path, params = {})
        self.class.get(path, headers: headers, query: params)
      end

      private

      def headers
        {
          "Authorization" => "Bearer #{@token}",
          "Accept" => "application/json"
        }
      end
    end
  end
end
