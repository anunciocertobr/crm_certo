# Mesmo padrão de Dropbox::IntegrationHelper — JWT assinado com o partner
# key do app Shopee, carregado no `state` do OAuth e verificado na volta
# (Api::V1::Integrations::ShopeeAuthorizationsController#callback).
module Shopee::IntegrationHelper
  def generate_shopee_token(identifier)
    return if shopee_partner_key.blank?

    JWT.encode({ sub: identifier, iat: Time.current.to_i }, shopee_partner_key, 'HS256')
  rescue StandardError => e
    Rails.logger.error("Failed to generate Shopee token: #{e.message}")
    nil
  end

  def verify_shopee_token(token)
    return if token.blank? || shopee_partner_key.blank?

    JWT.decode(token, shopee_partner_key, true, { algorithm: 'HS256', verify_expiration: true }).first['sub']
  rescue StandardError => e
    Rails.logger.error("Unexpected error verifying Shopee token: #{e.message}")
    nil
  end

  private

  def shopee_partner_key
    @shopee_partner_key ||= GlobalConfigService.load('SHOPEE_PARTNER_KEY', nil)
  end
end
