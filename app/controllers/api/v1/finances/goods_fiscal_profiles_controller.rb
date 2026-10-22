class Api::V1::Finances::GoodsFiscalProfilesController < Api::V1::BaseController
  before_action :set_profile, only: %i[update destroy]

  def index
    success_response(data: GoodsFiscalProfile.order(:razao_social).map { |p| serialize(p) })
  end

  def create
    profile = GoodsFiscalProfile.new(profile_params)
    assign_certificate(profile)

    if profile.save
      success_response(data: serialize(profile), status: :created)
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, profile.errors.full_messages.join(', '),
                     status: :unprocessable_entity)
    end
  end

  def update
    @profile.assign_attributes(profile_params)
    assign_certificate(@profile)

    if @profile.save
      success_response(data: serialize(@profile))
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, @profile.errors.full_messages.join(', '),
                     status: :unprocessable_entity)
    end
  end

  def destroy
    if @profile.destroy
      success_response(data: { id: @profile.id })
    else
      error_response(ApiErrorCodes::RESOURCE_IN_USE, @profile.errors.full_messages.join(', '),
                     status: :conflict)
    end
  end

  private

  def set_profile
    @profile = GoodsFiscalProfile.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Perfil fiscal não encontrado', status: :not_found)
  end

  def profile_params
    params.require(:goods_fiscal_profile).permit(
      :cnpj, :razao_social, :nome_fantasia, :uf, :inscricao_estadual, :crt,
      :ambiente, :provider_key, :serie_nfe, :serie_nfce, :active,
      # Endereço do emitente — exigido pela NF-e/NFC-e (<enderEmit>) quando
      # um provider_key de emissão real é escolhido (ver GoodsFiscalProfile).
      :logradouro, :numero_endereco, :complemento, :bairro,
      :codigo_municipio, :nome_municipio, :cep, :telefone
    )
  end

  # Certificado e CSC nunca voltam brutos pro frontend — só booleano
  # `configured` + data de expiração, mesmo padrão do FiscalEstablishment.
  def assign_certificate(profile)
    file = params.dig(:goods_fiscal_profile, :certificate_file)
    password = params.dig(:goods_fiscal_profile, :certificate_password)
    csc_id = params.dig(:goods_fiscal_profile, :csc_id)
    csc_token = params.dig(:goods_fiscal_profile, :csc_token)
    api_key = params.dig(:goods_fiscal_profile, :provider_api_key)

    profile.csc_id_encrypted = csc_id if csc_id.present?
    profile.csc_token_encrypted = csc_token if csc_token.present?
    profile.provider_api_key_encrypted = api_key if api_key.present?
    return if file.blank?

    profile.certificate_content_encrypted = Base64.strict_encode64(file.read)
    profile.certificate_password_encrypted = password if password.present?

    pkcs12 = profile.certificate_pkcs12
    profile.certificate_expires_at = pkcs12.certificate.not_after.to_date
  rescue OpenSSL::PKCS12::PKCS12Error
    profile.errors.add(:certificate_file, 'não pôde ser lido — verifique o arquivo e a senha')
  end

  def serialize(profile)
    profile.as_json(
      only: %i[id cnpj razao_social nome_fantasia uf inscricao_estadual crt ambiente
               provider_key serie_nfe numero_nfe_atual serie_nfce numero_nfce_atual
               logradouro numero_endereco complemento bairro codigo_municipio nome_municipio
               cep telefone active certificate_expires_at created_at updated_at]
    ).merge(configured: profile.configured?, csc_configured: profile.csc_id_encrypted.present?)
  end
end
