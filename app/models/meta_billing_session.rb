# Sessão única e compartilhada do Facebook usada pela automação de
# cobrança (PIX/boleto) de saldo pré-pago do Meta Ads — ver
# Meta::Billing::BrowserSession. Sempre acessar via .instance, nunca
# .create/.new direto, pra respeitar o singleton garantido pelo índice
# único de `lock_key`.
class MetaBillingSession < ApplicationRecord
  STATUSES = %w[idle active error].freeze

  encrypts :cookies_encrypted

  validates :status, inclusion: { in: STATUSES }

  def self.instance
    first_or_create!(lock_key: 'singleton')
  end

  def active?
    status == 'active' && cookies_encrypted.present?
  end
end
