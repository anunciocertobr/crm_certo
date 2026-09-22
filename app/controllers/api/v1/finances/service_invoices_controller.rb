class Api::V1::Finances::ServiceInvoicesController < Api::V1::BaseController
  before_action :set_service_invoice, only: %i[show cancel]

  def index
    invoices = ServiceInvoice.includes(:fiscal_establishment).order(created_at: :desc)
    success_response(data: invoices.map { |i| serialize(i) })
  end

  def show
    success_response(data: serialize(@invoice, include_xml: true))
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
                tomador_endereco discriminacao codigo_servico_municipal valor_servicos
                aliquota_iss_pct valor_iss valor_deducoes erro_mensagem created_at updated_at]
    fields += %i[xml_envio xml_retorno] if include_xml

    invoice.as_json(only: fields)
  end
end
