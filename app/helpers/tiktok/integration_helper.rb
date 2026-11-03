module Tiktok::IntegrationHelper
  # Mesmo padrão de Dropbox::IntegrationHelper — JWT assinado com o client
  # secret do app, usado como `state` do OAuth (prova que o callback veio
  # de um fluxo que este servidor iniciou, não de um CSRF).
  def generate_tiktok_token(identifier)
    return if tiktok_client_secret.blank?

    JWT.encode(tiktok_token_payload(identifier), tiktok_client_secret, 'HS256')
  rescue StandardError => e
    Rails.logger.error("Failed to generate TikTok token: #{e.message}")
    nil
  end

  def tiktok_token_payload(identifier)
    { sub: identifier, iat: Time.current.to_i }
  end

  def verify_tiktok_token(token)
    return if token.blank? || tiktok_client_secret.blank?

    decode_tiktok_token(token, tiktok_client_secret)
  end

  private

  def tiktok_client_secret
    @tiktok_client_secret ||= GlobalConfigService.load('TIKTOK_CLIENT_SECRET', nil)
  end

  def decode_tiktok_token(token, secret)
    JWT.decode(token, secret, true, {
                 algorithm: 'HS256',
                 verify_expiration: true
               }).first['sub']
  rescue StandardError => e
    Rails.logger.error("Unexpected error verifying TikTok token: #{e.message}")
    nil
  end
end
