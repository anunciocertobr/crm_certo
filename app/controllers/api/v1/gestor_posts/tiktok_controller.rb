module Api
  module V1
    module GestorPosts
      class TiktokController < BaseController
        def connected
          # ::Tiktok (prefixo top-level) — mesmo sombreamento de namespace já
          # documentado em Api::V1::Reports::HelenaWtsController pra
          # ::Meta/::Integrations: dentro de controllers em Api::V1::*, uma
          # referência sem `::` pode resolver pro módulo errado dependendo
          # do nesting léxico. Esta classe se chama TiktokController, então
          # o risco é menor aqui, mas prefixar sempre evita ter que provar
          # isso de novo se o nesting mudar.
          render json: { success: true, data: { connected: ::Tiktok::TokenService.new.connected? } }
        end

        def create
          if params[:video].blank?
            return render json: { success: false, errors: ['Arquivo de vídeo é obrigatório.'] }, status: :unprocessable_entity
          end

          upload = ::TiktokUpload.new(
            created_by: current_user.id,
            title: params[:title]
          )

          if upload.save
            upload.video.attach(params[:video])
            ::GestorPosts::TiktokUploadJob.perform_later(upload.id)
            render json: { success: true, data: upload_json(upload) }, status: :created
          else
            render json: { success: false, errors: upload.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def show
          upload = ::TiktokUpload.find(params[:id])
          render json: { success: true, data: upload_json(upload) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Upload não encontrado.'] }, status: :not_found
        end

        private

        def upload_json(upload)
          upload.as_json(only: %i[id title privacy_level status error_message external_post_id created_at])
        end
      end
    end
  end
end
