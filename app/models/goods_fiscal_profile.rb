# Emitente de NF-e 55 / NFC-e 65 — âmbito ESTADUAL (SEFAZ), independente de
# FiscalEstablishment (que é só pra NFS-e municipal, hoje só Guarulhos).
# Não reaproveita nada daquele model nem é usado por ele — ver pedido
# explícito do usuário de manter essa frente de NF-e separada da de NFS-e.
class GoodsFiscalProfile < ApplicationRecord
  AMBIENTES = %w[homologacao producao].freeze
  CRTS = %w[1 2 3 4].freeze # Simples | Simples excesso | Normal | MEI

  # Igual PROVIDER_CLIENTS de FiscalEstablishment: registro explícito
  # provider_key -> classe, nunca `constantize` direto de dado do banco.
  # 'sefaz_sp' é emissão DIRETA no webservice da SEFAZ-SP (sem contratar
  # nenhum provedor terceiro, pedido explícito do usuário) — ver
  # GoodsInvoices::SefazSp::Client. Sem provider_key escolhido, usa o stub
  # (GoodsInvoices::UnconfiguredProviderClient).
  PROVIDER_CLIENTS = {
    'sefaz_sp' => 'GoodsInvoices::SefazSp::Client'
  }.freeze

  encrypts :certificate_content_encrypted, :certificate_password_encrypted
  encrypts :csc_id_encrypted, :csc_token_encrypted
  encrypts :provider_api_key_encrypted

  has_many :goods_invoices, dependent: :restrict_with_error

  validates :cnpj, :razao_social, :uf, :inscricao_estadual, :crt, presence: true
  validates :logradouro, :numero_endereco, :bairro, :codigo_municipio, :nome_municipio, :cep,
            presence: true, if: -> { provider_key.present? }
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
