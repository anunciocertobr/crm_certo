# Consulta a situação de NFS-e ainda em processamento nos webservices
# municipais. Modelado em Ifood::PollEventsJob, mas com rescue POR NOTA
# dentro do loop (não um rescue único externo): esta job varre N notas de
# municípios possivelmente diferentes a cada execução, então uma prefeitura
# fora do ar não pode travar a consulta das outras.
module ServiceInvoices
  class PollStatusJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      ServiceInvoice.processing.find_each do |invoice|
        invoice.fiscal_establishment.provider_client.consultar_situacao(invoice)
      rescue StandardError => e
        Rails.logger.error("ServiceInvoices::PollStatusJob failed for invoice=#{invoice.id}: #{e.message}")
      end
    end
  end
end
