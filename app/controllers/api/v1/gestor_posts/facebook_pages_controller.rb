module Api
  module V1
    module GestorPosts
      class FacebookPagesController < BaseController
        def accessible
          render json: { success: true, data: service.accessible_pages }
        rescue ::Facebook::AccessiblePagesService::Error => e
          render json: { success: false, errors: [e.message] }, status: :unprocessable_entity
        end

        def connect
          channel = service.connect(params[:page_id])
          username = channel.instagram_id || channel.inbox&.name || channel.page_id
          render json: {
            success: true,
            data: { channel_type: 'Channel::FacebookPage', channel_id: channel.id, username: username, page_id: channel.page_id }
          }
        rescue ::Facebook::AccessiblePagesService::Error => e
          render json: { success: false, errors: [e.message] }, status: :unprocessable_entity
        end

        private

        def service
          @service ||= ::Facebook::AccessiblePagesService.new
        end
      end
    end
  end
end
