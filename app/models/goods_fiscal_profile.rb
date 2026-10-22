# Emitente de NF-e 55 / NFC-e 65 — âmbito ESTADUAL (SEFAZ), independente de
# FiscalEstablishment (que é só pra NFS-e municipal, hoje só Guarulhos).
# Não reaproveita nada daquele model nem é usado por ele — ver pedido
# explícito do usuário de manter essa frente de NF-e separada da de NFS-e.
class GoodsFiscalProfile < ApplicationRecord
  AMBIENTES = %w[homologacao producao].freeze
  CRTS = %w[1 2 3].freeze # 1 Simples Nacional | 2 Simples excesso | 3 Normal

  # Igual PROVIDER_CLIENTS de FiscalEstablishment: registro explícito
  # provider_key -> classe, nunca `constantize` direto de dado do banco.
  # Nenhum provedor certificado contratado ainda — ver
  # GoodsInvoices::UnconfiguredProviderClient.
  PROVIDER_CLIENTS = {}.freeze

  encrypts :certificate_content_encrypted, :certificate_password_encrypted
  encrypts :csc_id_encrypted, :csc_token_encrypted
  encrypts :provider_api_key_encrypted

  has_many :goods_invoices, dependent: :restrict_with_error

  validates :cnpj, :razao_social, :uf, :inscricao_estadual, :crt, presence: true
  validates :cnpj, uniqueness: true
  validates :ambiente, inclusion: { in: AMBIENTES }
  validates :crt, inclusion: { in: CRTS }
  validates :uf, length: { is: 2 }

  scope :active, -> { where(active: true) }

  def next_numero!(modelo)
    column = modelo.to_s == '65' ? :numero_nfce_atual : :numero_nfe_atual
    with_lock do
      increment!(column)
      self[column]
    end
  end

  def serie_for(modelo)
    modelo.to_s == '65' ? serie_nfce : serie_nfe
  end

  def certificate_pkcs12
    return nil if certificate_content_encrypted.blank?

    OpenSSL::PKCS12.new(Base64.decode64(certificate_content_encrypted), certificate_password_encrypted)
  end

  def configured?
    certificate_content_encrypted.present? && certificate_password_encrypted.present?
  end

  # Enquanto nenhum provedor certificado for contratado, todo emitente usa o
  # stub — que recusa emitir/consultar/cancelar com erro claro em vez de
  # fingir sucesso (ver GoodsInvoices::UnconfiguredProviderClient).
  def provider_client
    return GoodsInvoices::UnconfiguredProviderClient.new(self) if provider_key.blank?

    PROVIDER_CLIENTS.fetch(provider_key).constantize.new(self)
  end
end
