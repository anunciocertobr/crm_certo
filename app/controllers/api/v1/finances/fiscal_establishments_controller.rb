class Api::V1::Finances::FiscalEstablishmentsController < Api::V1::BaseController
  before_action :set_fiscal_establishment, only: %i[update destroy]

  def index
    success_response(data: FiscalEstablishment.order(:municipio_nome).map { |e| serialize(e) })
  end

  def create
    establishment = FiscalEstablishment.new(fiscal_establishment_params)
    assign_certificate(establishment)

    if establishment.save
      success_response(data: serialize(establishment), status: :created)
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, establishment.errors.full_messages.join(', '),
                     status: :unprocessable_entity)
    end
  end

  def update
    @establishment.assign_attributes(fiscal_establishment_params)
    assign_certificate(@establishment)

    if @establishment.save
      success_response(data: serialize(@establishment))
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, @establishment.errors.full_messages.join(', '),
                     status: :unprocessable_entity)
    end
  end

  def destroy
    if @establishment.destroy
      success_response(data: { id: @establishment.id })
    else
      error_response(ApiErrorCodes::RESOURCE_IN_USE, @establishment.errors.full_messages.join(', '),
                     status: :conflict)
    end
  end

  private

  def set_fiscal_establishment
    @establishment = FiscalEstablishment.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Estabelecimento fiscal não encontrado', status: :not_found)
  end

  def fiscal_establishment_params
    params.require(:fiscal_establishment).permit(
      :municipio_ibge_code, :municipio_nome, :uf, :inscricao_municipal,
      :cnae_override, :aliquota_iss_pct, :ambiente, :provider_key,
      :rps_serie, :active
    )
  end

  # Certificado nunca aparece bruto pro frontend de volta — só a data de
  # expiração e um booleano `configured`, igual o padrão de mascaramento de
  # segredo já usado em AppConfigsController.
  def assign_certificate(establishment)
    file = params.dig(:fiscal_establishment, :certificate_file)
    password = params.dig(:fiscal_establishment, :certificate_password)
    return if file.blank?

    establishment.certificate_content_encrypted = Base64.strict_encode64(file.read)
    establishment.certificate_password_encrypted = password if password.present?

    pkcs12 = establishment.certificate_pkcs12
    establishment.certificate_expires_at = pkcs12.certificate.not_after.to_date
  rescue OpenSSL::PKCS12::PKCS12Error
    establishment.errors.add(:certificate_file, 'não pôde ser lido — verifique o arquivo e a senha')
  end

  def serialize(establishment)
    establishment.as_json(
      only: %i[id municipio_ibge_code municipio_nome uf inscricao_municipal cnae_override
               aliquota_iss_pct ambiente provider_key rps_serie rps_numero_atual active
               certificate_expires_at created_at updated_at]
    ).merge(configured: establishment.configured?)
  end
end
