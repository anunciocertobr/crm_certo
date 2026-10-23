# Espelha Api::V1::MercadoLivreController/IfoodController no formato
# (status/sync/index/publish), mas sobre Shopee::Client — toda chamada
# exige assinatura HMAC própria, não só o login. NUNCA TESTADO CONTRA A API
# REAL — ver nota em Shopee::Client.
module Api
  module V1
    class ShopeeController < Api::V1::BaseController
      def status
        client = Shopee::Client.new
        render json: { success: true, data: { connected: client.connected?, shop_id: client.shop_id } }
      end

      def sync
        result = Shopee::SyncOrdersService.new.call
        render json: { success: true, data: ShopeeOrderSerializer.serialize_collection(ShopeeOrder.order_by_recent), meta: result }
      rescue Shopee::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def index
        render json: { success: true, data: ShopeeOrderSerializer.serialize_collection(ShopeeOrder.order_by_recent) }
      end

      def publish_product
        product = Product.find(params[:product_id])
        result = Shopee::PublishProductService.new.call(product)
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
