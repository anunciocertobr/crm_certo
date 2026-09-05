module GestorPosts
  # Publica um BusinessProfilePost como Local Post no Google Meu Negócio —
  # ver Google::BusinessProfileService.
  class BusinessProfilePublishJob < ApplicationJob
    queue_as :default

    def perform(business_profile_post_id)
      post = BusinessProfilePost.find_by(id: business_profile_post_id)
      return unless post

      post.mark_publishing!

      begin
        media_url = post.public_media_url
        raise Google::BusinessProfileService::Error, 'Não foi possível gerar a URL pública da mídia.' if media_url.blank?

        result = Google::BusinessProfileService.new.create_post(
          post.account_name, post.location_id,
          summary: post.summary, media_url: media_url,
          cta_action_type: post.cta_action_type.presence, cta_url: post.cta_url.presence
        )
        post.mark_published!(result['name'])
      rescue Google::BusinessProfileService::Error => e
        Rails.logger.error("GestorPosts::BusinessProfilePublishJob: #{e.message}")
        post.mark_failed!(e.message)
      end
    end
  end
end
