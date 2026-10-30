class Api::V1::Admin::MetaLeadFormsController < Api::V1::Admin::BaseController
  before_action :set_meta_lead_form, only: %i[update destroy]

  def index
    forms = MetaLeadForm.includes(meta_lead_form_pipelines: %i[pipeline pipeline_stage]).order(created_at: :desc)
    render json: { success: true, data: forms.map { |f| serialize(f) } }
  end

  def create
    form = MetaLeadForm.new(meta_lead_form_params)
    assign_pipelines(form)
    if form.save
      reprocess_pending_submissions(form)
      render json: { success: true, data: serialize(form.reload) }, status: :created
    else
      render json: { success: false, message: form.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def update
    @meta_lead_form.assign_attributes(meta_lead_form_params)
    assign_pipelines(@meta_lead_form)
    if @meta_lead_form.save
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

  # GET /meta_lead_forms/all_leads — aba "Formulário" do Rastreamentos.
  # Com 250 formulários mapeados, bater na Graph API ao vivo pra todos a
  # cada carregamento de página seria lento demais (250 chamadas reais);
  # por isso: (1) cacheia por form_id (15min — mesmo lead não muda de um
  # load pro outro nesse intervalo), (2) por padrão só os `limit`
  # formulários mapeados mais recentes (os mais relevantes pra
  # rastreamento de campanha em andamento), não os 250. `limit=0` busca
  # todos (pesado, de propósito não é o padrão).
  def all_leads
    limit = params[:limit].presence&.to_i
    forms = MetaLeadForm.order(created_at: :desc)
    forms = forms.limit(limit) if limit&.positive?

    leads = forms.flat_map { |form| leads_for_form(form) }
    leads.sort_by! { |l| l['created_time'].to_s }
    leads.reverse!

    render json: { success: true, data: leads.first(500) }
  end

  private

  def leads_for_form(form)
    Rails.cache.fetch("meta_form_leads_#{form.form_id}", expires_in: 15.minutes) do
      result = Meta::AdsManagerService.new.leadgen_form_leads(page_id: form.page_id, form_id: form.form_id)
      next [] unless result.success

      result.data.map { |lead| lead.merge('form_name' => form.form_name, 'form_id' => form.form_id) }
    end
  rescue StandardError => e
    Rails.logger.error("MetaLeadFormsController#all_leads form_id=#{form.form_id}: #{e.message}")
    []
  end

  # Sempre substitui a lista inteira pela recebida (o front manda o estado
  # completo desejado, não um diff) — destroy_all roda na hora (não espera o
  # save), e os novos ainda não salvos entram no mesmo save do form pela
  # autosave padrão de has_many.
  def assign_pipelines(form)
    return unless params.key?(:pipelines)

    form.meta_lead_form_pipelines.destroy_all if form.persisted?
    Array(params[:pipelines]).each do |p|
      form.meta_lead_form_pipelines.build(pipeline_id: p[:pipeline_id], pipeline_stage_id: p[:pipeline_stage_id])
    end
  end

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
    params.permit(:page_id, :form_id, :form_name, :mode, :active)
  end

  def serialize(form)
    {
      id: form.id,
      page_id: form.page_id,
      form_id: form.form_id,
      form_name: form.form_name,
      active: form.active,
      mode: form.mode,
      pipelines: form.meta_lead_form_pipelines.map do |p|
        {
          pipeline_id: p.pipeline_id,
          pipeline_stage_id: p.pipeline_stage_id,
          pipeline_name: p.pipeline&.name,
          pipeline_stage_name: p.pipeline_stage&.name
        }
      end,
      created_at: form.created_at&.iso8601
    }
  end
end
