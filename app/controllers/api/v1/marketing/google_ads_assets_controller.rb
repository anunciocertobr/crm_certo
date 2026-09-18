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

        private

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
