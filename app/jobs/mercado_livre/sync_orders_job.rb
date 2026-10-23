# Sincroniza pedidos do Mercado Livre periodicamente (config/schedule.yml).
# Diferente do Ifood::PollEventsJob, não existe aqui o requisito de
# "heartbeat" (a loja não aparece fechada por falta de polling) — a
# frequência é só pra manter a lista de pedidos atualizada.
module MercadoLivre
  class SyncOrdersJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      return unless MercadoLivre::Client.new.connected?

      MercadoLivre::SyncOrdersService.new.call
    rescue MercadoLivre::Client::Error => e
      Rails.logger.error("MercadoLivre::SyncOrdersJob failed: #{e.message}")
    end
  end
end
