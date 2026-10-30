# Orquestra a emissão de uma NFS-e: cria o ServiceInvoice com o próximo
# número de RPS do estabelecimento (nunca reaproveitado, ver
# FiscalEstablishment#next_rps_numero!) e delega a chamada real ao webservice
# municipal pro provider_client certo. Papel equivalente ao
# Ifood::SyncOrdersService — o job/controller chama isto, a lógica de
# integração fica no client.
module ServiceInvoices
  class EmissionService
    class Error < StandardError; end

    def initialize(fiscal_establishment:)
      @establishment = fiscal_establishment
    end

    def call(attrs)
      raise Error, 'Estabelecimento sem certificado configurado' unless @establishment.configured?

      invoice = build_invoice(attrs)
      invoice.save!
      @establishment.provider_client.emitir(invoice)
      schedule_fast_first_poll(invoice)
      invoice
    end

    private

    # Primeira consulta de status logo depois de emitir, sem esperar o
    # próximo ciclo do cron de 5 em 5 min (service_invoices_poll_status_job,
    # config/schedule.yml) — antes uma nota emitida poucos segundos depois
    # do ciclo anterior rodar ficava "processando" por quase 5 minutos até
    # a próxima varredura, mesmo já estando pronta no webservice municipal
    # bem antes disso. O cron de 5min continua existindo como rede de
    # segurança pras notas que demorarem mais que isso pra autorizar.
    def schedule_fast_first_poll(invoice)
      return unless invoice.reload.status == 'processing'

      ServiceInvoices::PollStatusJob.set(wait: 20.seconds).perform_later
    end

    def build_invoice(attrs)
      valor_servicos = attrs.fetch(:valor_servicos).to_f
      valor_deducoes = attrs[:valor_deducoes].to_f
      aliquota = (attrs[:aliquota_iss_pct] || @establishment.aliquota_iss_pct).to_f

      ServiceInvoice.new(
        attrs.merge(
          fiscal_establishment: @establishment,
          numero_rps: @establishment.next_rps_numero!.to_s,
          serie_rps: @establishment.rps_serie,
          aliquota_iss_pct: aliquota,
          valor_iss: attrs[:valor_iss] || ((valor_servicos - valor_deducoes) * aliquota / 100).round(2),
          status: 'pending'
        )
      )
    end
  end
end
