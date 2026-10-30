module Api
  module V1
    module Reports
      class HelenaWtsController < Api::V1::BaseController
        # ::Integrations (prefixo top-level) é necessário aqui: o módulo
        # Api::V1::Integrations (controllers de apps/hooks) existe no mesmo
        # nesting lexical desta classe e "sombreia" o Integrations de nível
        # raiz (services/models) — sem o `::`, Ruby resolve pra
        # Api::V1::Integrations::HelenaWts, que não existe, e explode com
        # "uninitialized constant" mesmo com o service certo no lugar certo.
        def contacts
          limit = (params[:limit].presence || 100).to_i
          page = (params[:page].presence || 1).to_i
          service = ::Integrations::HelenaWts::ContactsService.new
          result = service.list(page: page, limit: limit)
          render json: { items: result[:items], meta: result[:raw].is_a?(Hash) ? result[:raw].except("items", "data") : {} }, status: :ok
        rescue => e
          Rails.logger.error("[HelenaWts] contacts error: #{e.message}")
          render json: { error: e.message }, status: :bad_request
        end

        def all_contacts
          limit = (params[:limit].presence || 100).to_i
          service = ::Integrations::HelenaWts::ContactsService.new
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
