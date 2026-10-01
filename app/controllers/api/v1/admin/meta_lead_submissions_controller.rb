# Só leitura — mostra os leads que chegaram pelo webhook `leadgen` mas
# ficaram retidos (sem formulário mapeado, ou erro ao identificar
# telefone/e-mail), pra nenhum lead sumir silenciosamente. Mapear o
# formulário em MetaLeadFormsController já reprocessa esses automaticamente.
class Api::V1::Admin::MetaLeadSubmissionsController < Api::V1::Admin::BaseController
  def index
    statuses = params[:status].presence&.split(',') || %w[unmapped_form error]
    submissions = MetaLeadSubmission.where(status: statuses).order(created_at: :desc).limit(200)
    render json: { success: true, data: submissions.map { |s| serialize(s) } }
  end

  private

  def serialize(submission)
    {
      id: submission.id,
      leadgen_id: submission.leadgen_id,
      page_id: submission.page_id,
      form_id: submission.form_id,
      ad_name: submission.ad_name,
      adset_name: submission.adset_name,
      campaign_name: submission.campaign_name,
      status: submission.status,
      error_message: submission.error_message,
      field_data: submission.field_data,
      lead_created_time: submission.lead_created_time&.iso8601,
      created_at: submission.created_at&.iso8601
    }
  end
end
