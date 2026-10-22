# frozen_string_literal: true

# Um site cadastrado por URL (Dashboards > Sites). `webhook_token` é a
# credencial pública do webhook (ver Webhooks::SitesController) que recebe
# eventos de formulário/e-commerce de uma tag do Google Tag Manager do
# cliente — `has_secure_token` dá `regenerate_webhook_token` de graça
# (mesmo padrão de Channel::WebWidget#website_token).
class Site < ApplicationRecord
  has_secure_token :webhook_token

  has_many :site_lead_submissions, dependent: :nullify

  validates :url, presence: true

  before_validation :derive_hostname

  private

  def derive_hostname
    return if url.blank?

    self.hostname = URI.parse(url).host
  rescue URI::InvalidURIError
    self.hostname = nil
  end
end
