# Interação com uma confirmação pendente direto pela tela do CRM — mesmo
# efeito de responder "Confirmar"/"Recusar"/"Editar" no chat (ver
# ServiceInvoiceScheduleConfirmation#process_reply!), só que com campos de
# formulário em vez de texto livre. É o canal 'notification' (sino interno)
# na prática: toda confirmação pendente aparece em #pending independente de
# quais canais de chat também estiverem habilitados.
class Api::V1::Finances::ServiceInvoiceScheduleConfirmationsController < Api::V1::BaseController
  before_action :set_confirmation, only: %i[confirm decline edit_and_confirm]

  def pending
    confirmations = ServiceInvoiceScheduleConfirmation.where.not(
      status: %w[emitted declined no_response]
    ).order(scheduled_for: :asc)
    success_response(data: confirmations.map { |c| serialize(c) })
  end

  def confirm
    @confirmation.update!(status: 'confirmed', responded_at: Time.current)
    ServiceInvoices::ScheduleEmissionJob.perform_later(@confirmation.id)
    success_response(data: serialize(@confirmation))
  end

  def decline
    @confirmation.update!(status: 'declined', responded_at: Time.current)
    @confirmation.service_invoice_schedule.advance_next_run!
    success_response(data: serialize(@confirmation))
  end

  def edit_and_confirm
    overrides = edit_params.to_h.compact
    @confirmation.update!(
      overrides: @confirmation.overrides.merge(overrides),
      status: 'confirmed', responded_at: Time.current
    )
    ServiceInvoices::ScheduleEmissionJob.perform_later(@confirmation.id)
    success_response(data: serialize(@confirmation))
  end

  private

  def set_confirmation
    @confirmation = ServiceInvoiceScheduleConfirmation.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Confirmação não encontrada', status: :not_found)
  end

  def edit_params
    params.require(:overrides).permit(:valor_servicos, :discriminacao)
  end

  def serialize(confirmation)
    schedule = confirmation.service_invoice_schedule
    confirmation.as_json(
      only: %i[id scheduled_for status overrides notified_at responded_at erro_mensagem created_at]
    ).merge(
      service_invoice_schedule_id: schedule.id,
      tomador_nome: schedule.tomador_nome,
      invoice_attrs: confirmation.full_invoice_attrs
    )
  end
end
