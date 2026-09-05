# Mantém a integração "conectada" aos olhos do iFood. A Order API expõe o
# status da loja como fechada com o motivo "is.not.connected.config" sempre
# que o app para de chamar GET /events:polling com regularidade — não é uma
# pausa nem um problema de horário de funcionamento, é essa checagem de
# heartbeat. Antes desta job, o polling só acontecia quando alguém clicava
# em "Sincronizar" na aba Pedidos, então a loja aparecia fechada o tempo
# todo fora disso (confirmado via GET /merchants/:id/status real).
module Ifood
  class PollEventsJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      return unless Ifood::Client.configured?

      Ifood::SyncOrdersService.new.call
    rescue Ifood::Client::Error => e
      Rails.logger.error("Ifood::PollEventsJob failed: #{e.message}")
    end
  end
end
