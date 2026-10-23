# Roda a cada ~15min (ver config/schedule.yml). Pra cada ServiceInvoiceSchedule
# ativo cuja janela de aviso já chegou (next_run_at - notify_before), cria o
# ciclo de confirmação (ServiceInvoiceScheduleConfirmation) e dispara a
# notificação nos canais configurados. Nunca emite nada aqui — só avisa.
module ServiceInvoices
  class ScheduleNotificationJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      ServiceInvoiceSchedule.active.find_each do |schedule|
        next unless schedule.notify_at_for(schedule.next_run_at) <= Time.current
        next if schedule.confirmations.exists?(scheduled_for: schedule.next_run_at)

        notificar(schedule)
      end
    end

    private

    # Canal 'notification' não manda nada aqui — toda confirmação pendente já
    # aparece listada na tela de Nota Fiscal de Serviço (GET
    # /finances/service_invoice_schedules/pending_confirmations) assim que
    # status vira 'notified', independente do canal escolhido. Não usamos o
    # Notification/NotificationBuilder genérico do CRM porque ele pressupõe
    # primary_actor com `.contact` (pensado pra conversa) — estender isso
    # com segurança fica pra uma iteração futura, não bloqueia o essencial.
    def notificar(schedule)
      confirmation = schedule.confirmations.create!(
        scheduled_for: schedule.next_run_at, status: 'pending_notification'
      )

      ServiceInvoices::ScheduleNotifierService.notify!(confirmation) if (Array(schedule.channels) & %w[whatsapp telegram]).any?
      confirmation.update!(status: 'notified', notified_at: Time.current) if confirmation.status == 'pending_notification'
    rescue StandardError => e
      Rails.logger.error("[ServiceInvoices::ScheduleNotificationJob] schedule=#{schedule.id} #{e.class}: #{e.message}")
    end
  end
end
