module Api
  module V1
    module GestorPosts
      class BusinessProfileController < BaseController
        def connected
          render json: { success: true, data: { connected: Google::WorkspaceTokenService.new.connected? } }
        end

        def locations
          render json: { success: true, data: service.all_locations }
        rescue ::Google::BusinessProfileService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def location
          render json: { success: true, data: service.location(params.require(:location_name)) }
        rescue ::Google::BusinessProfileService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def update_location
          data = service.update_location(
            params.require(:location_name),
            fields: params.require(:fields).permit!.to_h,
            update_mask: Array(params.require(:update_mask))
          )
          render json: { success: true, data: data }
        rescue ::Google::BusinessProfileService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def search_categories
          render json: { success: true, data: service.search_categories(params.require(:query)) }
        rescue ::Google::BusinessProfileService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def posts
          data = service.posts(params.require(:account_name), params.require(:location_id))
          render json: { success: true, data: data }
        rescue ::Google::BusinessProfileService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        def show
          post = ::BusinessProfilePost.find(params[:id])
          render json: { success: true, data: post_json(post) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Post não encontrado.'] }, status: :not_found
        end

        def create
          if params[:media].blank? || params[:summary].blank?
            return render json: { success: false, errors: ['Mídia e legenda são obrigatórias.'] }, status: :unprocessable_entity
          end

          post = ::BusinessProfilePost.new(
            created_by: current_user.id,
            account_name: params.require(:account_name),
            location_id: params.require(:location_id),
            location_title: params[:location_title],
            summary: params[:summary],
            cta_action_type: params[:cta_action_type].presence,
            cta_url: params[:cta_url].presence
          )

          if post.save
            post.media.attach(params[:media])
            ::GestorPosts::BusinessProfilePublishJob.perform_later(post.id)
            render json: { success: true, data: post_json(post) }, status: :created
          else
            render json: { success: false, errors: post.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy_post
          service.delete_post(params.require(:post_name))
          render json: { success: true, data: nil }
        rescue ::Google::BusinessProfileService::Error => e
          render json: { success: false, errors: [e.message] }, status: :bad_gateway
        end

        private

        def service
          @service ||= ::Google::BusinessProfileService.new
        end

        def post_json(post)
          post.as_json(only: %i[id account_name location_id location_title summary cta_action_type cta_url status
                                error_message external_post_name created_at])
        end
      end
    end
  end
end
