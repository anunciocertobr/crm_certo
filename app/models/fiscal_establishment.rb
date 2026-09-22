# Um registro por município onde a empresa tem inscrição municipal e pode
# emitir NFS-e. Cada município usa um webservice/provedor diferente
# (`provider_key` escolhe o client certo — ver PROVIDER_CLIENTS) e exige seu
# próprio certificado digital A1 (guardado aqui já criptografado via Active
# Record Encryption, não no GlobalConfig — que é pensado pra valor pequeno
# em cache Redis, não pra segredo binário com necessidade de FK/lock).
class FiscalEstablishment < ApplicationRecord
  AMBIENTES = %w[homologacao producao].freeze

  # Registro explícito provider_key -> classe, em vez de `constantize` direto
  # numa string vinda do banco (evita instanciar classe arbitrária a partir
  # de dado persistido).
  PROVIDER_CLIENTS = {
    'guarulhos_gissonline' => 'Guarulhos::Client'
  }.freeze

  encrypts :certificate_content_encrypted, :certificate_password_encrypted

  has_many :service_invoices, dependent: :restrict_with_error

  validates :municipio_ibge_code, :municipio_nome, :uf, :inscricao_municipal,
            :aliquota_iss_pct, :provider_key, presence: true
  validates :municipio_ibge_code, uniqueness: true
  validates :ambiente, inclusion: { in: AMBIENTES }
  validates :provider_key, inclusion: { in: PROVIDER_CLIENTS.keys }
  validates :uf, length: { is: 2 }

  scope :active, -> { where(active: true) }

  # Nunca reaproveitar/pular um número de RPS pra mesma série — a prefeitura
  # rejeita (ou pior, aceita como duplicado) se dois pedidos concorrentes
  # gerarem o mesmo número. `with_lock` segue o mesmo padrão já usado em
  # CarouselUploadBatch#with_lock.
  def next_rps_numero!
    with_lock do
      self.rps_numero_atual += 1
      save!
      rps_numero_atual
    end
  end

  def certificate_pkcs12
    return nil if certificate_content_encrypted.blank?

    OpenSSL::PKCS12.new(Base64.decode64(certificate_content_encrypted), certificate_password_encrypted)
  end

  def configured?
    certificate_content_encrypted.present? && certificate_password_encrypted.present?
  end

  def provider_client
    PROVIDER_CLIENTS.fetch(provider_key).constantize.new(self)
  end
end
