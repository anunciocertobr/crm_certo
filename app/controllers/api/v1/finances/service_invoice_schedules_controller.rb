class Api::V1::Finances::ServiceInvoiceSchedulesController < Api::V1::BaseController
  before_action :set_schedule, only: %i[update destroy]

  def index
    success_response(data: ServiceInvoiceSchedule.order(:next_run_at).map { |s| serialize(s) })
  end

  def create
    schedule = ServiceInvoiceSchedule.new(schedule_params)

    if schedule.save
      success_response(data: serialize(schedule), status: :created)
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, schedule.errors.full_messages.join(', '), status: :unprocessable_entity)
    end
  end

  def update
    @schedule.assign_attributes(schedule_params)
    if @schedule.save
      success_response(data: serialize(@schedule))
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, @schedule.errors.full_messages.join(', '), status: :unprocessable_entity)
    end
  end

  def destroy
    @schedule.destroy
    success_response(data: { id: @schedule.id })
  end

  private

  def set_schedule
    @schedule = ServiceInvoiceSchedule.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Agendamento não encontrado', status: :not_found)
  end

  def schedule_params
    params.require(:service_invoice_schedule).permit(
      :fiscal_establishment_id, :tomador_nome, :tomador_cpf_cnpj, :tomador_email,
      :discriminacao, :codigo_servico_municipal, :codigo_nbs, :codigo_tributacao_municipio,
      :valor_servicos, :valor_deducoes, :aliquota_iss_pct,
      :recurrence_type, :day_of_month, :day_of_week, :next_run_at,
      :notify_before_value, :notify_before_unit,
      :notify_whatsapp_number, :notify_telegram_chat_id, :active,
      tomador_endereco: %i[logradouro numero bairro codigo_municipio uf cep],
      channels: []
    )
  end

  def serialize(schedule)
    schedule.as_json(
      only: %i[id fiscal_establishment_id tomador_nome tomador_cpf_cnpj tomador_email tomador_endereco
               discriminacao codigo_servico_municipal codigo_nbs codigo_tributacao_municipio
               valor_servicos valor_deducoes aliquota_iss_pct recurrence_type day_of_month day_of_week
               next_run_at notify_before_value notify_before_unit channels
               notify_whatsapp_number notify_telegram_chat_id active created_at updated_at]
    )
  end
end
