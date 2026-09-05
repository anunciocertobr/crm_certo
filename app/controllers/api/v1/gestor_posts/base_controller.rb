module Api
  module V1
    module GestorPosts
      class BaseController < Api::V1::BaseController
        # Lista as contas Instagram-capazes conectadas (Channel::Instagram e
        # Channel::FacebookPage com instagram_id), pra tela escolher qual usar.
        def channels
          instagram = Channel::Instagram.all.map do |c|
            { channel_type: 'Channel::Instagram', channel_id: c.id, username: c.instagram_id }
          end
          facebook_pages = Channel::FacebookPage.where.not(instagram_id: nil).map do |c|
            { channel_type: 'Channel::FacebookPage', channel_id: c.id, username: c.instagram_id, page_id: c.page_id }
          end

          render json: { success: true, data: instagram + facebook_pages }
        end

        # TODAS as páginas do Facebook já conectadas como canal aqui, com ou
        # sem Instagram vinculado — diferente de #channels acima, que só
        # inclui as com Instagram (usado pelas telas específicas do
        # Instagram). Esta é a lista usada pelo seletor de página do
        # Facebook no Gestor de Posts.
        def facebook_channels
          data = Channel::FacebookPage.all.map do |c|
            { channel_type: 'Channel::FacebookPage', channel_id: c.id, username: c.instagram_id || c.inbox&.name || c.page_id, page_id: c.page_id }
          end

          render json: { success: true, data: data }
        end

        private

        def social_channel
          @social_channel ||= case params[:channel_type]
                               when 'Channel::Instagram' then Channel::Instagram.find(params[:channel_id])
                               when 'Channel::FacebookPage' then Channel::FacebookPage.find(params[:channel_id])
                               else
                                 Channel::Instagram.first || Channel::FacebookPage.where.not(instagram_id: nil).first
                               end
        rescue ActiveRecord::RecordNotFound
          nil
        end

        def require_social_channel!
          return if social_channel.present?

          render json: { success: false, errors: ['Nenhuma conta Instagram conectada.'] }, status: :unprocessable_entity
        end
      end
    end
  end
end
