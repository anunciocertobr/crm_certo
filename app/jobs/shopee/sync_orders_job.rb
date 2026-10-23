# Sincroniza pedidos da Shopee periodicamente (config/schedule.yml) — mesmo
# raciocínio do MercadoLivre::SyncOrdersJob, sem requisito de heartbeat.
module Shopee
  class SyncOrdersJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      return unless Shopee::Client.new.connected?

      Shopee::SyncOrdersService.new.call
    rescue Shopee::Client::Error => e
      Rails.logger.error("Shopee::SyncOrdersJob failed: #{e.message}")
    end
  end
end
