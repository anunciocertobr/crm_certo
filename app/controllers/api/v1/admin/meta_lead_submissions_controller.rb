# Mostra leads recebidos pelo webhook `leadgen` — tanto os retidos (sem
# formulário mapeado, ou erro ao identificar telefone/e-mail — pra nenhum
# lead sumir silenciosamente) quanto, via `show`/`update`, qualquer um já
# processado, pro painel "Ver Leads" (LeadFormLeadsDialog.tsx) mostrar/editar
# as colunas que não vêm da Graph API. Mapear o formulário em
# MetaLeadFormsController já reprocessa os retidos automaticamente.
#
# `:id` na rota é o `leadgen_id` (o id do lead na Graph API), não o UUID
# interno do registro — é o único identificador que a tela "Ver Leads" tem
# em mãos, já que ela busca os leads direto na Graph API, não deste banco
# (ver Meta::AdsManagerService#leadgen_form_leads).
class Api::V1::Admin::MetaLeadSubmissionsController < Api::V1::Admin::BaseController
  before_action :set_meta_lead_submission, only: %i[show update]

  def index
    statuses = params[:status].presence&.split(',') || %w[unmapped_form error]
    submissions = MetaLeadSubmission.where(status: statuses).order(created_at: :desc).limit(200)
    render json: { success: true, data: submissions.map { |s| serialize(s) } }
  end

  def show
    render json: { success: true, data: serialize(@submission, full: true) }
  end

  # Só os dois campos que fazem sentido editar manualmente: status (fila de
  # atendimento do lead) e pra qual fase do Kanban o card ligado está —
  # reaproveita PipelineItem#move_to_stage, a mesma lógica que o Kanban usa
  # ao arrastar um card, pra não duplicar a lógica de movimentação/histórico.
  def update
    if lead_params[:status].present?
      @submission.update!(status: lead_params[:status])
    end

    if lead_params[:pipeline_stage_id].present?
      item = @submission.pipeline_item
      return error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION, 'Lead sem card de Kanban vinculado — não dá pra mover fase.', status: :unprocessable_entity) unless item

      new_stage = PipelineStage.find_by(id: lead_params[:pipeline_stage_id], pipeline_id: item.pipeline_id)
      return error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Fase não encontrada neste pipeline.', status: :not_found) unless new_stage

      item.move_to_stage(new_stage)
    end

    render json: { success: true, data: serialize(@submission.reload, full: true) }
  rescue ActiveRecord::RecordInvalid => e
    error_response(ApiErrorCodes::BUSINESS_RULE_VIOLATION, e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
  end

  private

  def set_meta_lead_submission
    @submission = MetaLeadSubmission.find_by!(leadgen_id: params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Lead não encontrado.', status: :not_found)
  end

  def lead_params
    params.permit(:status, :pipeline_stage_id)
  end

  def serialize(submission, full: false)
    item = submission.pipeline_item
    base = {
      id: submission.id,
      leadgen_id: submission.leadgen_id,
      page_id: submission.page_id,
      form_id: submission.form_id,
      ad_id: submission.ad_id,
      adset_id: submission.adset_id,
      campaign_id: submission.campaign_id,
      ad_name: submission.ad_name,
      adset_name: submission.adset_name,
      campaign_name: submission.campaign_name,
      status: submission.status,
      error_message: submission.error_message,
      field_data: submission.field_data,
      lead_created_time: submission.lead_created_time&.iso8601,
      created_at: submission.created_at&.iso8601,
      notified_whatsapp_at: submission.notified_whatsapp_at&.iso8601,
      contact_id: submission.contact_id,
      pipeline_item_id: item&.id,
      pipeline_id: item&.pipeline_id,
      pipeline_name: item&.pipeline&.name,
      pipeline_stage_id: item&.pipeline_stage_id,
      pipeline_stage_name: item&.pipeline_stage&.name
    }
    return base unless full

    base.merge(
      contact_name: submission.contact&.name,
      contact_phone: submission.contact&.phone_number,
      contact_email: submission.contact&.email,
      lead_quality: item&.lead_quality,
      lead_score: item&.lead_score,
      lead_objection: item&.lead_objection,
      lead_observation: item&.lead_observation,
      available_stages: item && PipelineStage.where(pipeline_id: item.pipeline_id).order(:position).map { |s| { id: s.id, name: s.name } }
    )
  end
end
