# Espelha Api::V1::IfoodController no formato (status/sync/index/publish),
# mas sobre MercadoLivre::Client — OAuth2 por vendedor (Integrations::Hook),
# não client_credentials global. #status/#sync testados contra a API real
# (26/10/2026) — ver nota em MercadoLivre::Client. #publish_product ainda
# sem teste real (nenhum produto publicado ainda).
#
# #products/#questions/#reviews testados contra a API real (30/10/2026).
# #answer_question/#messages/#send_message sem teste real (sem pergunta
# pendente nem pedido com pack_id ainda) — ver nota em MercadoLivre::Client.
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

      # Anúncios JÁ PUBLICADOS na loja (diferente de #publish_product, que
      # cria um novo) — lista os ids e busca os detalhes (nome/preço/status/
      # foto) de uma vez, pra tela não precisar de uma chamada por item.
      def products
        client = MercadoLivre::Client.new
        ids = client.my_items(status: params[:status].presence)['results'] || []
        render json: { success: true, data: client.items_details(ids) }
      rescue MercadoLivre::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def questions
        data = MercadoLivre::Client.new.questions(status: params[:status].presence || 'UNANSWERED')
        render json: { success: true, data: data }
      rescue MercadoLivre::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def answer_question
        MercadoLivre::Client.new.answer_question(params.require(:question_id), text: params.require(:text))
        render json: { success: true }
      rescue MercadoLivre::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      # Só leitura — a API do ML (diferente da do iFood) não deixa o
      # vendedor responder avaliação, só consultar.
      def reviews
        data = MercadoLivre::Client.new.reviews(params.require(:item_id))
        render json: { success: true, data: data }
      rescue MercadoLivre::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def messages
        order = MercadoLivreOrder.find(params[:order_id])
        data = MercadoLivre::Client.new.messages(pack_id_for(order))
        render json: { success: true, data: data }
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, errors: ['Pedido não encontrado'] }, status: :not_found
      rescue MercadoLivre::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      def send_message
        order = MercadoLivreOrder.find(params[:order_id])
        MercadoLivre::Client.new.send_message(pack_id_for(order), text: params.require(:text))
        render json: { success: true }
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, errors: ['Pedido não encontrado'] }, status: :not_found
      rescue MercadoLivre::Client::Error => e
        render json: { success: false, errors: [e.message] }, status: :bad_gateway
      end

      private

      # Pedido fora de um "pack" (envio agrupado) não tem pack_id — a API
      # documenta cair pro próprio id do pedido nesse caso.
      def pack_id_for(order)
        order.raw_payload['pack_id'] || order.ml_order_id
      end
    end
  end
end
