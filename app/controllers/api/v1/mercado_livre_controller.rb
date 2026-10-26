# Espelha Api::V1::IfoodController no formato (status/sync/index/publish),
# mas sobre MercadoLivre::Client — OAuth2 por vendedor (Integrations::Hook),
# não client_credentials global. #status/#sync testados contra a API real
# (26/10/2026) — ver nota em MercadoLivre::Client. #publish_product ainda
# sem teste real (nenhum produto publicado ainda).
module Api
  module V1
    class MercadoLivreController < Api::V1::BaseController
      def status
        client = MercadoLivre::Client.new
        render json: { success: true, data: { connected: client.connected?, user_id: client.user_id } }
      end

      def sync
        result = MercadoLivre::SyncOrdersService.new.call
        render json: { success: true, data: MercadoLivreOrderSerializer.serialize_collection(MercadoLivreOrder.order_by_recent), meta: result }
      rescue MercadoLivre::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def index
        render json: { success: true, data: MercadoLivreOrderSerializer.serialize_collection(MercadoLivreOrder.order_by_recent) }
      end

      def publish_product
        product = Product.find(params[:product_id])
        result = MercadoLivre::PublishProductService.new.call(product)
        if result.success
          render json: { success: true }
        else
          render json: { success: false, errors: [result.error] }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, errors: ['Produto não encontrado'] }, status: :not_found
      end
    end
  end
end
