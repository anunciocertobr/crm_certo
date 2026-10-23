# Mesmo padrão de Dropbox::IntegrationHelper — JWT assinado com o client
# secret do app ML, carregado no `state` do OAuth e verificado na volta
# (Api::V1::Integrations::MercadoLivreAuthorizationsController#callback)
# pra garantir que o callback não foi forjado.
module MercadoLivre::IntegrationHelper
  def generate_mercado_livre_token(identifier)
    return if mercado_livre_client_secret.blank?

    JWT.encode({ sub: identifier, iat: Time.current.to_i }, mercado_livre_client_secret, 'HS256')
  rescue StandardError => e
    Rails.logger.error("Failed to generate Mercado Livre token: #{e.message}")
    nil
  end

  def verify_mercado_livre_token(token)
    return if token.blank? || mercado_livre_client_secret.blank?

    JWT.decode(token, mercado_livre_client_secret, true, { algorithm: 'HS256', verify_expiration: true }).first['sub']
  rescue StandardError => e
    Rails.logger.error("Unexpected error verifying Mercado Livre token: #{e.message}")
    nil
  end

  private

  def mercado_livre_client_secret
    @mercado_livre_client_secret ||= GlobalConfigService.load('MERCADO_LIVRE_CLIENT_SECRET', nil)
  end
end
