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

        # GET /reports/helena_wts/ad_context?ad_id=... — nome do anúncio/
        # conjunto/campanha + criativo a partir do ad_id (utm.sourceId dos
        # contatos Helena/WTS, ver RastreamentosPage no front). Cacheado
        # 12h por ad_id (mesmo TTL de Meta::ConversionsApiService#pixel_id_
        # for_ad) — o front já dedup antes de chamar, mas o cache evita
        # repetir a chamada à Graph API em reloads subsequentes da página.
        def ad_context
          ad_id = params[:ad_id].presence
          return render json: { error: 'Informe ad_id.' }, status: :bad_request if ad_id.blank?

          cache_key = "rastreamentos_ad_context_#{ad_id}"
          cached = Rails.cache.read(cache_key)
          if cached
            render json: { success: true, data: cached }
            return
          end

          result = Meta::AdsManagerService.new.ad_context(ad_id: ad_id)
          if result.success
            Rails.cache.write(cache_key, result.data, expires_in: 12.hours)
            render json: { success: true, data: result.data }
          else
            render json: { success: false, error: result.error }, status: :bad_gateway
          end
        end

        # POST /reports/helena_wts/send_conversion — "Enviar pro Meta"
        # (Conversions API) pra um contato Helena/WTS, mesmo destino que o
        # fluxo automático de WhatsApp (Meta::ConversionsApiService#
        # send_event), só que manual e sem precisar de um AdLead no banco
        # (contato Helena nunca tem um — vem de fora do CRM). AdLeadLike/
        # ContactLike abaixo só implementam os métodos que send_event lê
        # (ad_id/ctwaclid/fbp/fbc, phone_number), sem precisar de
        # ActiveRecord pra isso.
        AdLeadLike = Struct.new(:ad_id, :ctwaclid, :fbp, :fbc, keyword_init: true)
        ContactLike = Struct.new(:phone_number, keyword_init: true)

        def send_conversion
          ad_id = params[:ad_id].presence
          return render json: { success: false, error: 'Informe ad_id.' }, status: :unprocessable_entity if ad_id.blank?

          ad_lead = AdLeadLike.new(ad_id: ad_id, ctwaclid: params[:ctwa_clid].presence, fbp: nil, fbc: nil)
          contact = ContactLike.new(phone_number: params[:phone].presence)

          result = Meta::ConversionsApiService.new.send_event(
            event_name: params[:event_name].presence || 'Lead',
            ad_lead: ad_lead,
            contact: contact,
            custom_data: send_conversion_custom_data_params.to_h
          )
          render json: { success: result.success, error: result.error, data: result.data }
        end

        private

        def send_conversion_custom_data_params
          params.fetch(:custom_data, {}).permit(
            :currency, :value, :content_name, :content_category, :content_type,
            :order_id, :num_items, :search_string, :status, :delivery_category, :predicted_ltv
          )
        end
      end
    end
  end
end
