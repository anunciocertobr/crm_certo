module Api
  module V1
    module Reports
      class HelenaWtsController < Api::V1::BaseController
        def contacts
          limit = (params[:limit].presence || 100).to_i
          page = (params[:page].presence || 1).to_i
          service = Integrations::HelenaWts::ContactsService.new
          result = service.list(page: page, limit: limit)
          render json: { items: result[:items], meta: result[:raw].is_a?(Hash) ? result[:raw].except("items", "data") : {} }, status: :ok
        rescue => e
          Rails.logger.error("[HelenaWts] contacts error: #{e.message}")
          render json: { error: e.message }, status: :bad_request
        end

        def all_contacts
          limit = (params[:limit].presence || 100).to_i
          service = Integrations::HelenaWts::ContactsService.new
          items = service.fetch_all(limit: limit)
          render json: { items: items }, status: :ok
        rescue => e
          Rails.logger.error("[HelenaWts] all_contacts error: #{e.message}")
          render json: { error: e.message }, status: :bad_request
        end
      end
    end
  end
end
