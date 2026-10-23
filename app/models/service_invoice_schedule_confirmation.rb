# Um ciclo de confirmação de ServiceInvoiceSchedule. O "estado da conversa"
# fica aqui, não espalhado em listeners — ServiceInvoices::ScheduleNotifier
# Service só manda/recebe mensagem; quem decide o que fazer com a resposta é
# este model.
class ServiceInvoiceScheduleConfirmation < ApplicationRecord
  STATUSES = %w[
    pending_notification notified
    awaiting_edit_field awaiting_edit_value awaiting_edit_confirmation
    confirmed declined emitted error no_response
  ].freeze

  # "editar" só cobre estes 2 campos nesta 1ª versão (os mais pedidos —
  # valor e descrição do serviço). Pra outros campos, editar direto na tela
  # de Nota Fiscal de Serviço antes de confirmar.
  EDITABLE_FIELDS = {
    'valor' => :valor_servicos,
    'descricao' => :discriminacao,
    'descrição' => :discriminacao
  }.freeze

  belongs_to :service_invoice_schedule
  belongs_to :service_invoice, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :scheduled_for, presence: true

  def full_invoice_attrs
    service_invoice_schedule.base_invoice_attrs.merge(overrides.symbolize_keys)
  end

  # Chamado pelo listener (NfseScheduleConfirmationListener) quando chega
  # mensagem incoming na conversa marcada. `channel` é 'whatsapp'/'telegram'
  # — só usado pra saber em qual conversa responder de volta.
  def process_reply!(channel, raw_text)
    texto = normalizar(raw_text)

    case status
    when 'notified'
      processar_resposta_inicial(texto, channel)
    when 'awaiting_edit_field'
      processar_escolha_campo(texto, channel)
    when 'awaiting_edit_value'
      processar_novo_valor(raw_text, channel)
    when 'awaiting_edit_confirmation'
      processar_confirmacao_edicao(texto, channel)
    end
    # Qualquer outro status (já confirmado/recusado/emitido) ignora — é
    # mensagem tardia numa conversa já resolvida.
  end

  private

  def normalizar(texto)
    texto.to_s.strip.downcase.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '')
  end

  def processar_resposta_inicial(texto, channel)
    case texto
    when 'confirmar'
      confirmar_e_emitir!(channel)
    when 'recusar', 'nao', 'não'
      recusar!(channel)
    when 'editar'
      update!(status: 'awaiting_edit_field')
      ServiceInvoices::ScheduleNotifierService.reply!(
        self, channel, 'O que deseja mudar?',
        buttons: [{ title: 'Valor', value: 'valor' }, { title: 'Descrição', value: 'descricao' },
                  { title: 'Cancelar', value: 'cancelar' }]
      )
    else
      ServiceInvoices::ScheduleNotifierService.reply!(
        self, channel, 'Não entendi. Responda *Confirmar*, *Recusar* ou *Editar*.'
      )
    end
  end

  def processar_escolha_campo(texto, channel)
    if texto == 'cancelar'
      update!(status: 'notified')
      return reenviar_resumo(channel)
    end

    campo = EDITABLE_FIELDS[texto]
    unless campo
      return ServiceInvoices::ScheduleNotifierService.reply!(
        self, channel, 'Não entendi o campo. Responda *Valor*, *Descrição* ou *Cancelar*.'
      )
    end

    update!(status: 'awaiting_edit_value', pending_edit_field: campo.to_s)
    pergunta = campo == :valor_servicos ? 'Qual o novo valor (ex: 600.00)?' : 'Qual a nova descrição do serviço?'
    ServiceInvoices::ScheduleNotifierService.reply!(self, channel, pergunta)
  end

  def processar_novo_valor(raw_text, channel)
    campo = pending_edit_field.to_sym
    valor = campo == :valor_servicos ? parse_valor(raw_text) : raw_text.strip

    if campo == :valor_servicos && valor.nil?
      return ServiceInvoices::ScheduleNotifierService.reply!(self, channel, 'Valor inválido. Responda só o número, ex: 600.00')
    end

    update!(overrides: overrides.merge(campo.to_s => valor.to_s), status: 'awaiting_edit_confirmation', pending_edit_field: nil)
    reenviar_resumo(channel, prefixo: 'Confirma emitir com essa mudança?')
  end

  def processar_confirmacao_edicao(texto, channel)
    case texto
    when 'confirmar'
      confirmar_e_emitir!(channel)
    when 'recusar', 'cancelar', 'nao', 'não'
      recusar!(channel)
    else
      ServiceInvoices::ScheduleNotifierService.reply!(self, channel, 'Responda *Confirmar* ou *Recusar*.')
    end
  end

  def parse_valor(texto)
    normalizado = texto.to_s.strip.gsub('.', '').tr(',', '.') # aceita "1.200,50" e "1200.50"
    normalizado = texto.to_s.strip if texto.to_s.count(',') == 0 && texto.to_s.count('.') <= 1
    Float(normalizado)
  rescue ArgumentError, TypeError
    nil
  end

  def confirmar_e_emitir!(channel)
    update!(status: 'confirmed', responded_at: Time.current)
    ServiceInvoices::ScheduleNotifierService.reply!(self, channel, '✅ Confirmado! Emitindo a NFS-e agora...')
    ServiceInvoices::ScheduleEmissionJob.perform_later(id)
  end

  def recusar!(channel)
    update!(status: 'declined', responded_at: Time.current)
    ServiceInvoices::ScheduleNotifierService.reply!(self, channel, 'Entendido, essa emissão não vai sair. Até o próximo ciclo.')
    service_invoice_schedule.advance_next_run!
  end

  def reenviar_resumo(channel, prefixo: nil)
    ServiceInvoices::ScheduleNotifierService.reply!(
      self, channel, ServiceInvoices::ScheduleNotifierService.resumo_texto(self, prefixo: prefixo),
      buttons: [{ title: 'Confirmar', value: 'confirmar' }, { title: 'Recusar', value: 'recusar' },
                { title: 'Editar', value: 'editar' }]
    )
  end
end
