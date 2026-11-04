require 'net/http'
require 'uri'
require 'json'

# Tiktok::TokenService - devolve um access_token válido pra conta TikTok
# conectada em Configurações > Integrações > TikTok (armazenada em
# Integrations::Hook, app_id: 'tiktok' — ver TiktokAuthorizationsController).
# Renova via refresh_token quando expirado. Mesmo padrão de
# Google::WorkspaceTokenService, mas sem o gem oauth2 (TikTok não usa esse
# client) — POST direto na Graph API de token deles.
#
# Token da TikTok dura só ~24h (bem mais curto que o do Google), então essa
# renovação é esperada acontecer com frequência bem maior aqui.
class Tiktok::TokenService
  TOKEN_URL = 'https://open.tiktokapis.com/v2/oauth/token/'

  def access_token
    return nil unless hook

    return settings['access_token'] unless expired?

    refresh!
  end

  def connected?
    hook.present?
  end

  private

  def hook
    @hook ||= Integrations::Hook.find_by(app_id: 'tiktok')
  end

  def settings
    (hook.settings || {}).with_indifferent_access
  end

  def expired?
    expiry = settings['expires_on']
    return true if expiry.blank?

    Time.current.utc >= DateTime.parse(expiry) - 5.minutes
  end

  def refresh!
    return nil if settings['refresh_token'].blank?

    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'client_key' => GlobalConfigService.load('TIKTOK_CLIENT_KEY', nil),
                                      'client_secret' => GlobalConfigService.load('TIKTOK_CLIENT_SECRET', nil),
                                      'grant_type' => 'refresh_token',
                                      'refresh_token' => settings['refresh_token']
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    body = JSON.parse(response.body)
    return nil if body['access_token'].blank?

    hook.settings = settings.merge(
      'access_token' => body['access_token'],
      'refresh_token' => body['refresh_token'] || settings['refresh_token'],
      'expires_on' => (Time.current.utc + body['expires_in'].to_i.seconds).to_s
    )
    hook.save!

    body['access_token']
  rescue StandardError => e
    Rails.logger.error "Tiktok::TokenService: refresh failed: #{e.message}"
    nil
  end
end
