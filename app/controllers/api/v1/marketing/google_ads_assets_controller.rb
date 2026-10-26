module Api
  module V1
    module Marketing
      class GoogleAdsAssetsController < Api::V1::BaseController
        before_action :fetch_asset, only: %i[update destroy]

        def index
          scope = GoogleAdsAsset.alphabetical
          scope = scope.by_kind(params[:kind]) if params[:kind].present?
          render json: { success: true, data: scope.map { |a| GoogleAdsAssetSerializer.serialize(a) } }
        end

        def create
          asset = GoogleAdsAsset.new(asset_params)
          if asset.save
            render json: { success: true, data: GoogleAdsAssetSerializer.serialize(asset) }, status: :created
          else
            render json: { success: false, errors: asset.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @asset.update(asset_params)
            render json: { success: true, data: GoogleAdsAssetSerializer.serialize(@asset) }
          else
            render json: { success: false, errors: @asset.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @asset.destroy
          render json: { success: true, message: 'Removido com sucesso' }
        end

        # Lista campanhas reais da conta Google Ads conectada, pra popular o
        # seletor "publicar nesta campanha" — sem isso, o publish liga o
        # asset na conta inteira.
        def campaigns
          customer_id = params[:customer_id].to_s.gsub(/\D/, '').presence
          return render_not_connected unless customer_id

          result = Google::AdsInfrastructureService.new(login_customer_id: params[:login_customer_id]).list_campaigns(customer_id: customer_id)
          if result.success
            render json: { success: true, data: result.data }
          else
            render json: { success: false, errors: [result.error] }, status: :unprocessable_entity
          end
        end

        # Publica um GoogleAdsAsset de verdade na Google Ads API — exige
        # canal conectado E conta selecionada (customer_id, do MCC/conexão
        # identificado por login_customer_id). `campaign_id` é opcional:
        # sem ele, liga o asset na conta inteira.
        def publish
          asset = GoogleAdsAsset.find(params[:id])
          customer_id = params[:customer_id].to_s.gsub(/\D/, '').presence
          return render_not_connected unless customer_id

          result = Google::AdsAssetPublisher.new(infrastructure_service: Google::AdsInfrastructureService.new(login_customer_id: params[:login_customer_id])).publish(
            google_ads_asset: asset, customer_id: customer_id, campaign_id: params[:campaign_id].presence
          )

          if result.success
            asset.update!(
              published_at: Time.current,
              google_resource_names: result.data[:resource_names],
              google_customer_id: customer_id
            )
            render json: { success: true, data: GoogleAdsAssetSerializer.serialize(asset) }
          else
            render json: { success: false, errors: [result.error] }, status: :unprocessable_entity
          end
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Não encontrado'] }, status: :not_found
        end

        private

        def render_not_connected
          render json: { success: false, errors: ['Conecte uma conta Google Ads em Integrações antes de publicar.'] },
                 status: :unprocessable_entity
        end

        def fetch_asset
          @asset = GoogleAdsAsset.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Não encontrado'] }, status: :not_found
        end

        # `payload` varia de formato por `kind` (público/palavra-chave/título) —
        # fica livre aqui de propósito, cada tipo valida seu próprio formato
        # no frontend, igual o TargetingList faz com `items`.
        def asset_params
          params.require(:google_ads_asset).permit(:kind, :name, payload: {})
        end
      end
    end
  end
end
