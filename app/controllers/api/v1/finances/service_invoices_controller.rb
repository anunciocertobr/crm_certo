class Api::V1::Finances::ServiceInvoicesController < Api::V1::BaseController
  before_action :set_service_invoice, only: %i[show cancel pdf send_pdf destroy]

  # Filtros opcionais (todos vazios = comportamento de sempre, lista tudo) —
  # usados tanto pela tabela normal quanto pelo dashboard de gráficos
  # (ver ServiceInvoiceDashboardDialog no frontend).
  def index
    invoices = ServiceInvoice.includes(:fiscal_establishment).order(created_at: :desc)
    invoices = invoices.where('tomador_nome ILIKE ?', "%#{params[:tomador_nome]}%") if params[:tomador_nome].present?
    invoices = invoices.where('tomador_cpf_cnpj ILIKE ?', "%#{params[:tomador_cpf_cnpj]}%") if params[:tomador_cpf_cnpj].present?
    invoices = invoices.where('discriminacao ILIKE ?', "%#{params[:discriminacao]}%") if params[:discriminacao].present?
    invoices = invoices.where('created_at >= ?', Date.parse(params[:date_from]).beginning_of_day) if params[:date_from].present?
    invoices = invoices.where('created_at <= ?', Date.parse(params[:date_to]).end_of_day) if params[:date_to].present?
    success_response(data: invoices.map { |i| serialize(i) })
  rescue ArgumentError
    error_response(ApiErrorCodes::INVALID_PARAMETER, 'date_from/date_to inválidos (use YYYY-MM-DD)', status: :bad_request)
  end

  def show
    success_response(data: serialize(@invoice, include_xml: true))
  end

  # DANFSe gerado on-the-fly a partir do xml_retorno + colunas do invoice —
  # ver ServiceInvoices::DanfsePdfService pro porquê de não depender de
  # nenhum portal público da prefeitura.
  def pdf
    unless @invoice.authorized?
      return error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION,
                             'NFS-e ainda não autorizada — sem dados da prefeitura pra gerar o PDF',
                             status: :unprocessable_entity)
    end

    pdf_data = ServiceInvoices::DanfsePdfService.call(@invoice)
    send_data pdf_data, filename: "nfse-#{@invoice.numero_nfse || @invoice.numero_rps}.pdf",
                         type: 'application/pdf', disposition: 'inline'
  rescue ServiceInvoices::DanfsePdfService::Error => e
    error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION, e.message, status: :unprocessable_entity)
  end

  # POST /finances/service_invoices/:id/send_pdf — manda o mesmo DANFSe de
  # `pdf` direto por WhatsApp (inbox + número OU grupo), reaproveitando
  # Reports::ReportPdfSenderService (mesmo serviço do botão "Enviar" dos
  # relatórios PDF — ver app/services/reports/report_pdf_sender_service.rb).
  def send_pdf
    unless @invoice.authorized?
      return error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION,
                             'NFS-e ainda não autorizada — sem dados da prefeitura pra gerar o PDF',
                             status: :unprocessable_entity)
    end

    pdf_data = ServiceInvoices::DanfsePdfService.call(@invoice)
    result = Reports::ReportPdfSenderService.call(
      pdf_bytes: pdf_data,
      filename: "nfse-#{@invoice.numero_nfse || @invoice.numero_rps}.pdf",
      inbox_id: params.require(:inbox_id),
      whatsapp_number: params[:whatsapp_number],
      group_jid: params[:group_jid],
      group_name: params[:group_name],
      created_by: current_user&.id,
      contact_name: 'NFS-e'
    )

    if result.success
      success_response(data: { sent: true })
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :unprocessable_entity)
    end
  rescue ServiceInvoices::DanfsePdfService::Error => e
    error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION, e.message, status: :unprocessable_entity)
  end

  def create
    establishment = FiscalEstablishment.active.find(service_invoice_params[:fiscal_establishment_id])
    invoice = ServiceInvoices::EmissionService.new(fiscal_establishment: establishment).call(invoice_attrs)
    success_response(data: serialize(invoice), status: :created)
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Estabelecimento fiscal não encontrado', status: :not_found)
  rescue ServiceInvoices::EmissionService::Error, ActiveRecord::RecordInvalid => e
    error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION, e.message, status: :unprocessable_entity)
  rescue NotaFiscal::ProviderClient::Error, StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, "Falha ao emitir NFS-e: #{e.message}",
                   status: :bad_gateway)
  end

  def cancel
    @invoice.fiscal_establishment.provider_client.cancelar(@invoice)
    success_response(data: serialize(@invoice))
  rescue StandardError => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, "Falha ao cancelar NFS-e: #{e.message}",
                   status: :bad_gateway)
  end

  # DELETE /finances/service_invoices/:id — só pra registros status=error,
  # de propósito: nunca foram transmitidos com sucesso (numero_nfse vazio),
  # então apagar aqui não altera nada perante a prefeitura, é só limpar o
  # histórico de tentativas falhas (pedido do usuário). authorized/
  # processing/pending continuam só podendo ser cancelados (ver #cancel),
  # nunca apagados — são registro fiscal real ou em andamento.
  def destroy
    unless @invoice.status == 'error'
      return error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION,
                             'Só é possível excluir notas com erro — autorizada/processando precisa ser cancelada.',
                             status: :unprocessable_entity)
    end

    @invoice.destroy!
    success_response(data: { id: @invoice.id })
  end

  private

  def set_service_invoice
    @invoice = ServiceInvoice.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Nota fiscal não encontrada', status: :not_found)
  end

  def service_invoice_params
    params.require(:service_invoice).permit(
      :fiscal_establishment_id, :work_order_id, :tomador_nome, :tomador_cpf_cnpj,
      :tomador_email, :discriminacao, :codigo_servico_municipal,
      :codigo_nbs, :codigo_tributacao_municipio,
      :valor_servicos, :valor_deducoes, :aliquota_iss_pct,
      tomador_endereco: %i[logradouro numero bairro codigo_municipio uf cep]
    )
  end

  def invoice_attrs
    service_invoice_params.except(:fiscal_establishment_id).to_h.symbolize_keys
  end

  def serialize(invoice, include_xml: false)
    fields = %i[id fiscal_establishment_id work_order_id numero_rps serie_rps numero_nfse
                codigo_verificacao protocolo status tomador_nome tomador_cpf_cnpj tomador_email
                tomador_endereco discriminacao codigo_servico_municipal codigo_nbs
                codigo_tributacao_municipio valor_servicos
                aliquota_iss_pct valor_iss valor_deducoes erro_mensagem created_at updated_at]
    fields += %i[xml_envio xml_retorno] if include_xml

    invoice.as_json(only: fields)
  end
end
