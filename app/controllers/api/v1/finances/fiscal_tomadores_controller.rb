class Api::V1::Finances::FiscalTomadoresController < Api::V1::BaseController
  before_action :set_fiscal_tomador, only: %i[update destroy]

  def index
    success_response(data: FiscalTomador.alphabetical.map { |t| serialize(t) })
  end

  def create
    tomador = FiscalTomador.new(fiscal_tomador_params)
    if tomador.save
      success_response(data: serialize(tomador), status: :created)
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, tomador.errors.full_messages.join(', '),
                     status: :unprocessable_entity)
    end
  end

  def update
    if @tomador.update(fiscal_tomador_params)
      success_response(data: serialize(@tomador))
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, @tomador.errors.full_messages.join(', '),
                     status: :unprocessable_entity)
    end
  end

  def destroy
    @tomador.destroy
    success_response(data: { id: @tomador.id })
  end

  private

  def set_fiscal_tomador
    @tomador = FiscalTomador.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Tomador não encontrado', status: :not_found)
  end

  def fiscal_tomador_params
    params.require(:fiscal_tomador).permit(
      :nome, :cpf_cnpj, :email,
      endereco: %i[logradouro numero bairro codigo_municipio uf cep]
    )
  end

  def serialize(tomador)
    tomador.as_json(only: %i[id nome cpf_cnpj email endereco created_at updated_at])
  end
end
