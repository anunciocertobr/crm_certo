module Whatsapp::EvolutionGoHandlers::ContentHandlers
  include Whatsapp::AdReferralCapture

  private

  def extract_content
    # Content extraction is handled directly in MessagesUpsert
    Rails.logger.debug 'Evolution Go API: Content processing handled in MessagesUpsert'
  end

  def extract_from_baileys_structure
    # Evolution Go doesn't use Baileys structure in the same way
    Rails.logger.debug 'Evolution Go API: Baileys structure extraction not used'
  end

  # `@evolution_go_message` já é o nível `message` (equivalente a
  # `@raw_message[:message]` da Evolution clássica — ver
  # Whatsapp::AdReferralCapture para o porquê da busca ser recursiva em vez
  # de um caminho fixo).
  def handle_ad_referral
    return unless incoming?

    capture_baileys_ad_referral(
      node: @evolution_go_message,
      contact: @contact,
      conversation: @conversation,
      message: @message,
      log_prefix: 'Evolution Go API'
    )
  end
end
