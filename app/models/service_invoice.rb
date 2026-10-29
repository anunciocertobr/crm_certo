# Uma NFS-e emitida (ou em processo de emissão) através de um
# FiscalEstablishment. `xml_envio`/`xml_retorno` ficam em texto plano — não
# são segredo, são dado fiscal, e o histórico completo importa pra eventual
# disputa com a prefeitura sobre uma rejeição.
class ServiceInvoice < ApplicationRecord
  STATUSES = %w[pending processing authorized error cancelled].freeze

  belongs_to :fiscal_establishment
  belongs_to :work_order, optional: true
  has_one_attached :pdf

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :numero_rps, :serie_rps, :tomador_nome, :tomador_cpf_cnpj,
            :discriminacao, :codigo_servico_municipal, presence: true
  # codigo_nbs NÃO é mais obrigatório (era, até 29/10/2026) — a prefeitura
  # de Guarulhos (schema v2_04/eicon) recusou duas emissões reais com esse
  # campo preenchido (erro E160 "Arquivo em desacordo com o XML Schema"),
  # mesmo o manual técnico pós-Reforma Tributária marcando como "Ocorr.
  # 1-1" — o schema real em uso ainda não aceita. Ver
  # Guarulhos::Client#servico_node, que só inclui <CodigoNbs> no XML
  # quando presente agora.
  validates :numero_rps, uniqueness: { scope: %i[fiscal_establishment_id serie_rps] }
  validates :valor_servicos, :aliquota_iss_pct, :valor_iss,
            numericality: { greater_than_or_equal_to: 0 }

  scope :processing, -> { where(status: 'processing') }

  def authorized?
    status == 'authorized'
  end
end
