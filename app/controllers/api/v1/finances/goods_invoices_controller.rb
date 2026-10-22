class Api::V1::Finances::GoodsInvoicesController < Api::V1::BaseController
  before_action :set_invoice, only: %i[show cancel]

  def index
    invoices = GoodsInvoice.includes(:goods_fiscal_profile).order(created_at: :desc)
    success_response(data: invoices.map { |i| serialize(i) })
  end

  def show
    success_response(data: serialize(@invoice, include_xml: true))
  end

  def create
    profile = GoodsFiscalProfile.active.find(invoice_params[:goods_fiscal_profile_id])
    invoice = GoodsInvoices::EmissionService.new(fiscal_profile: profile).call(invoice_attrs)
    success_response(data: serialize(invoice), status: :created)
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Perfil fiscal não encontrado', status: :not_found)
  rescue ActiveRecord::RecordInvalid => e
    error_response(ApiErrorCodes::VALIDATION_ERROR, e.message, status: :unprocessable_entity)
  end

  def cancel
    @invoice.goods_fiscal_profile.provider_client.cancelar(@invoice)
    success_response(data: serialize(@invoice))
  rescue GoodsInvoices::ProviderClient::Error => e
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, e.message, status: :bad_gateway)
  end

  private

  def set_invoice
    @invoice = GoodsInvoice.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Nota fiscal não encontrada', status: :not_found)
  end

  def invoice_params
    params.require(:goods_invoice).permit(
      :goods_fiscal_profile_id, :work_order_id, :modelo, :natureza_operacao,
      :destinatario_nome, :destinatario_cpf_cnpj, :forma_pagamento,
      # valor_produtos/valor_total NÃO são aceitos do cliente — o
      # EmissionService recalcula os dois a partir dos itens.
      :valor_desconto, :valor_frete,
      destinatario_endereco: %i[logradouro numero bairro codigo_municipio uf cep],
      # product_id é o que importa de verdade: GoodsInvoices::EmissionService
      # recalcula o imposto de cada item via Tax::CalculationService a partir
      # dele (NCM/CFOP/CST/CSOSN/redução vêm do cadastro do produto, não do
      # que o front mandar aqui — os demais campos do item são só pra exibir
      # o que foi usado/editado na hora da venda).
      itens: %i[product_id descricao ncm cfop cst_csosn origem quantidade valor_unitario
                valor_total cclasstrib]
    )
  end

  def invoice_attrs
    invoice_params.except(:goods_fiscal_profile_id).to_h.symbolize_keys
  end

  def serialize(invoice, include_xml: false)
    fields = %i[id goods_fiscal_profile_id work_order_id modelo numero serie natureza_operacao
                status chave_acesso protocolo data_emissao destinatario_nome destinatario_cpf_cnpj
                forma_pagamento
                destinatario_endereco itens valor_produtos valor_desconto valor_frete valor_total
                regime_tributario valor_cbs valor_ibs valor_imposto_seletivo valor_legado
                valor_total_impostos avisos_fiscais
                erro_mensagem created_at updated_at]
    fields += %i[xml_envio xml_retorno] if include_xml

    invoice.as_json(only: fields)
  end
end
