class Api::V1::Admin::MetaLeadFormsController < Api::V1::Admin::BaseController
  before_action :set_meta_lead_form, only: %i[update destroy]

  def index
    forms = MetaLeadForm.includes(:pipeline, :pipeline_stage).order(created_at: :desc)
    render json: { success: true, data: forms.map { |f| serialize(f) } }
  end

  def create
    form = MetaLeadForm.new(meta_lead_form_params)
    if form.save
      reprocess_pending_submissions(form)
      render json: { success: true, data: serialize(form.reload) }, status: :created
    else
      render json: { success: false, message: form.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def update
    if @meta_lead_form.update(meta_lead_form_params)
      reprocess_pending_submissions(@meta_lead_form)
      render json: { success: true, data: serialize(@meta_lead_form.reload) }
    else
      render json: { success: false, message: @meta_lead_form.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def destroy
    @meta_lead_form.destroy
    render json: { success: true }
  end

  private

  # Um formulário recém-mapeado (ou remapeado pra outro pipeline/estágio)
  # libera na hora qualquer lead que já tinha chegado sem mapeamento —
  # ninguém precisa esperar o próximo lead novo pra ver os que já vieram.
  def reprocess_pending_submissions(form)
    MetaLeadSubmission.where(form_id: form.form_id, status: %w[unmapped_form error]).find_each do |submission|
      Meta::LeadAds::ImportService.reprocess(submission)
    end
  end

  def set_meta_lead_form
    @meta_lead_form = MetaLeadForm.find(params[:id])
  end

  def meta_lead_form_params
    params.permit(:page_id, :form_id, :form_name, :pipeline_id, :pipeline_stage_id, :active)
  end

  def serialize(form)
    {
      id: form.id,
      page_id: form.page_id,
      form_id: form.form_id,
      form_name: form.form_name,
      active: form.active,
      pipeline_id: form.pipeline_id,
      pipeline_stage_id: form.pipeline_stage_id,
      pipeline_name: form.pipeline&.name,
      pipeline_stage_name: form.pipeline_stage&.name,
      created_at: form.created_at&.iso8601
    }
  end
end
