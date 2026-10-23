# Template de NFS-e recorrente — nunca emite sozinho. Cada ciclo (ocorrência)
# cria um ServiceInvoiceScheduleConfirmation que precisa ser confirmado por
# chat (WhatsApp/Telegram) ou na própria tela do CRM antes de emitir de
# verdade (ver ServiceInvoices::ScheduleNotificationJob/ScheduleEmissionJob).
class ServiceInvoiceSchedule < ApplicationRecord
  RECURRENCE_TYPES = %w[once monthly weekly].freeze
  NOTIFY_BEFORE_UNITS = %w[days hours].freeze
  CHANNELS = %w[whatsapp telegram notification].freeze

  belongs_to :fiscal_establishment
  has_many :confirmations, class_name: 'ServiceInvoiceScheduleConfirmation', dependent: :destroy

  validates :tomador_nome, :tomador_cpf_cnpj, :discriminacao, :codigo_servico_municipal,
            :codigo_nbs, :valor_servicos, :next_run_at, presence: true
  validates :recurrence_type, inclusion: { in: RECURRENCE_TYPES }
  validates :notify_before_unit, inclusion: { in: NOTIFY_BEFORE_UNITS }
  validates :notify_before_value, numericality: { greater_than: 0 }
  validates :day_of_month, inclusion: { in: 1..28 }, allow_nil: true
  validates :day_of_week, inclusion: { in: 0..6 }, allow_nil: true
  validate :channels_validos
  validate :recurrence_fields_presentes
  validate :pelo_menos_um_canal_configurado

  scope :active, -> { where(active: true) }

  def notify_at_for(scheduled_for)
    notify_before_unit == 'hours' ? scheduled_for - notify_before_value.hours : scheduled_for - notify_before_value.days
  end

  # Atributos pra ServiceInvoices::EmissionService — mesmo formato de
  # service_invoice_params no controller. overrides (de uma confirmação
  # específica) sobrescrevem só o que vier preenchido.
  def base_invoice_attrs
    {
      tomador_nome: tomador_nome,
      tomador_cpf_cnpj: tomador_cpf_cnpj,
      tomador_email: tomador_email,
      tomador_endereco: tomador_endereco,
      discriminacao: discriminacao,
      codigo_servico_municipal: codigo_servico_municipal,
      codigo_nbs: codigo_nbs,
      codigo_tributacao_municipio: codigo_tributacao_municipio,
      valor_servicos: valor_servicos,
      valor_deducoes: valor_deducoes,
      aliquota_iss_pct: aliquota_iss_pct
    }
  end

  # Avança next_run_at pra próxima ocorrência (ou desativa, se for 'once').
  def advance_next_run!
    if recurrence_type == 'once'
      update!(active: false)
      return
    end

    base = next_run_at
    novo = case recurrence_type
           when 'monthly'
             base.next_month.change(day: [day_of_month, base.next_month.end_of_month.day].min)
           when 'weekly'
             base + 1.week
           end
    update!(next_run_at: novo)
  end

  private

  def channels_validos
    invalidos = Array(channels) - CHANNELS
    errors.add(:channels, "inválido(s): #{invalidos.join(', ')}") if invalidos.any?
  end

  def recurrence_fields_presentes
    errors.add(:day_of_month, 'obrigatório pra recorrência mensal') if recurrence_type == 'monthly' && day_of_month.blank?
    errors.add(:day_of_week, 'obrigatório pra recorrência semanal') if recurrence_type == 'weekly' && day_of_week.blank?
  end

  def pelo_menos_um_canal_configurado
    return if Array(channels).any?

    errors.add(:channels, 'escolha pelo menos um canal de notificação')
  end
end
