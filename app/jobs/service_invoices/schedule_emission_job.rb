# Duas responsabilidades:
#  1) Emitir de verdade as confirmações já respondidas 'confirmed' (chamado
#     tanto pelo cron de varredura quanto diretamente pelo model quando a
#     pessoa confirma no chat — ver ServiceInvoiceScheduleConfirmation#
#     confirmar_e_emitir!).
#  2) Marcar como 'no_response' (e NUNCA emitir) os ciclos cujo horário
#     agendado já passou sem resposta — silêncio nunca vira emissão.
module ServiceInvoices
  class ScheduleEmissionJob < ApplicationJob
    queue_as :scheduled_jobs

    AGUARDANDO_RESPOSTA = %w[notified awaiting_edit_field awaiting_edit_value awaiting_edit_confirmation].freeze

    def perform(confirmation_id = nil)
      if confirmation_id
        confirmation = ServiceInvoiceScheduleConfirmation.find_by(id: confirmation_id)
        emitir(confirmation) if confirmation&.status == 'confirmed'
        return
      end

      ServiceInvoiceScheduleConfirmation.where(status: 'confirmed').find_each { |c| emitir(c) }
      ServiceInvoiceScheduleConfirmation.where(status: AGUARDANDO_RESPOSTA)
                                         .where('scheduled_for < ?', Time.current)
                                         .find_each { |c| marcar_sem_resposta(c) }
    end

    private

    def emitir(confirmation)
      schedule = confirmation.service_invoice_schedule
      invoice = ServiceInvoices::EmissionService.new(fiscal_establishment: schedule.fiscal_establishment)
                                                 .call(confirmation.full_invoice_attrs)
      confirmation.update!(status: 'emitted', service_invoice: invoice)
      schedule.advance_next_run!
    rescue StandardError => e
      confirmation.update!(status: 'error', erro_mensagem: e.message)
      Rails.logger.error("[ServiceInvoices::ScheduleEmissionJob] confirmation=#{confirmation.id} #{e.class}: #{e.message}")
    end

    def marcar_sem_resposta(confirmation)
      confirmation.update!(status: 'no_response', responded_at: Time.current)
      Array(confirmation.conversation_ids).each do |channel, _conversation_id|
        ServiceInvoices::ScheduleNotifierService.reply!(
          confirmation, channel, 'Não tivemos resposta a tempo — essa emissão não saiu. Até o próximo ciclo.'
        )
      end
      confirmation.service_invoice_schedule.advance_next_run!
    rescue StandardError => e
      Rails.logger.error("[ServiceInvoices::ScheduleEmissionJob] no_response confirmation=#{confirmation.id} #{e.message}")
    end
  end
end
