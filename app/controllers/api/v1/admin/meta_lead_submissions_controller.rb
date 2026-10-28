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
  before_action :set_meta_lead_submission, only: %i[update]

  def index
    statuses = params[:status].presence&.split(',') || %w[unmapped_form error]
    submissions = MetaLeadSubmission.where(status: statuses).order(created_at: :desc).limit(200)
    render json: { success: true, data: submissions.map { |s| serialize(s) } }
  end

  # Formulário "só notificar" (mode: notify_only) nunca persiste
  # MetaLeadSubmission — sem isso, o painel "Ver Leads" ficava sem
  # telefone/nome/ad_id pra pré-preencher o envio manual pro Meta (pedido
  # do usuário). Sem registro no banco, busca o lead ao vivo na Graph API
  # (mesmo endpoint que o ImportService usa na hora de importar) — exige
  # `page_id` como query param, já que sem MetaLeadSubmission não tem como
  # saber de qual Página o lead veio.
  def show
    submission = MetaLeadSubmission.find_by(leadgen_id: params[:id])
    if submission
      render json: { success: true, data: serialize(submission, full: true) }
      return
    end

    render_live_lookup
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

  # POST /meta_lead_submissions/send_to_meta_crm — envio manual, único e
  # explícito (botão "Enviar" na tela "Ver Leads"), pro Conversion Leads da
  # Meta. Funciona só com leadgen_id (nunca precisa de MetaLeadSubmission
  # existir no banco — é assim que formulários notify_only, que nunca
  # persistem nada, também conseguem usar isso) e NUNCA grava nada: nem o
  # payload mandado, nem o resultado. Pode mandar pra mais de um dataset de
  # uma vez (fan-out), cada um falha isoladamente.
  #
  # user_data/custom_data são o schema completo da Conversions API (ver
  # Meta::ConversionsApiCrmService::HASHED_USER_FIELDS/PLAIN_USER_FIELDS/
  # CUSTOM_DATA_FIELDS) — o front manda só o que o usuário preencheu, campo
  # vazio não entra no payload.
  def send_to_meta_crm
    leadgen_id = params[:leadgen_id]
    dataset_ids = Array(params[:dataset_ids]).map(&:to_s).reject(&:blank?)
    return error_response(ApiErrorCodes::VALIDATION_ERROR, 'Informe o leadgen_id.', status: :unprocessable_entity) if leadgen_id.blank?
    return error_response(ApiErrorCodes::VALIDATION_ERROR, 'Informe ao menos um dataset.', status: :unprocessable_entity) if dataset_ids.empty?

    user_data = send_to_meta_crm_user_data_params.to_h
    user_data[:lead_id] = leadgen_id if user_data[:lead_id].blank?
    custom_data = send_to_meta_crm_custom_data_params.to_h

    service = Meta::ConversionsApiCrmService.new
    results = dataset_ids.map do |dataset_id|
      result = service.send_manual_event(
        event_name: params[:event_name].presence || 'Lead',
        dataset_id: dataset_id,
        action_source: params[:action_source].presence || 'system_generated',
        user_data: user_data,
        custom_data: custom_data
      )
      { dataset_id: dataset_id, success: result.success, error: result.error, meta_response: result.data }
    end

    render json: { success: results.any? { |r| r[:success] }, data: results }
  end

  # GET /meta_lead_submissions/pixels_for_ad?ad_id=... — pixels/datasets da
  # conta de anúncios de onde o lead veio, pro seletor de dataset do envio
  # manual (MetaCrmSendForm.tsx) vir preenchido sozinho em vez de uma lista
  # fixa configurada manualmente antes.
  def pixels_for_ad
    result = Meta::PixelsLookupService.new.pixels_for_ad(params[:ad_id])
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: { success: true, data: result.data }
  end

  private

  # leadgen_id sem MetaLeadSubmission no banco (notify_only, ou formulário
  # mapeado depois do lead ter chegado) — busca ao vivo na Graph API só pra
  # pré-preencher o envio manual (ad_id pros pixels, nome/telefone/e-mail
  # parseados do field_data). `found: false` sinaliza pro front mostrar o
  # mesmo aviso de sempre ("não passou pelo CRM"), só que agora com os
  # campos já preenchidos em vez de em branco.
  def render_live_lookup
    leadgen_id = params[:id]
    page_id = params[:page_id]
    return render json: { success: true, data: empty_live_lookup(leadgen_id) } if page_id.blank?

    result = Meta::AdsManagerService.new.lead_detail(page_id: page_id, leadgen_id: leadgen_id)
    return render json: { success: true, data: empty_live_lookup(leadgen_id) } unless result.success

    parsed = Meta::LeadAds::FieldParser.parse(result.data['field_data'])
    render json: {
      success: true,
      data: {
        found: false,
        leadgen_id: leadgen_id,
        ad_id: result.data['ad_id'],
        adset_id: result.data['adset_id'],
        campaign_id: result.data['campaign_id'],
        field_data: result.data['field_data'],
        contact_name: parsed[:name],
        contact_phone: parsed[:phone],
        contact_email: parsed[:email]
      }
    }
  end

  # Mesmas chaves sempre presentes (mesmo nil) nos dois caminhos de
  # render_live_lookup — contrato fixo que o frontend espera
  # (MetaLeadSubmissionLiveLookup), nunca um subconjunto.
  def empty_live_lookup(leadgen_id)
    { found: false, leadgen_id: leadgen_id, ad_id: nil, adset_id: nil, campaign_id: nil,
      field_data: [], contact_name: nil, contact_phone: nil, contact_email: nil }
  end

  def set_meta_lead_submission
    @submission = MetaLeadSubmission.find_by!(leadgen_id: params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Lead não encontrado.', status: :not_found)
  end

  def lead_params
    params.permit(:status, :pipeline_stage_id)
  end

  def send_to_meta_crm_user_data_params
    params.fetch(:user_data, {}).permit(
      :em, :ph, :fn, :ln, :ge, :db, :ct, :st, :zp, :country, :external_id,
      :lead_id, :client_ip_address, :client_user_agent, :fbc, :fbp
    )
  end

  def send_to_meta_crm_custom_data_params
    params.fetch(:custom_data, {}).permit(
      :currency, :value, :content_name, :content_category, :content_type,
      :order_id, :num_items, :search_string, :status, :delivery_category, :predicted_ltv,
      content_ids: []
    )
  end

  def serialize(submission, full: false)
    item = submission.pipeline_item
    base = {
      found: true,
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

    # Fallback pro field_data bruto do formulário quando o Contact do CRM
    # não tem o campo (nunca foi criado com telefone/nome certos, ou era um
    # campo custom que o parser na hora do import não reconheceu) — pedido
    # do usuário: "não está preenchendo telefone e nome sendo que já tem no
    # formulário".
    parsed_fields = Meta::LeadAds::FieldParser.parse(submission.field_data)
    base.merge(
      contact_name: submission.contact&.name.presence || parsed_fields[:name],
      contact_phone: submission.contact&.phone_number.presence || parsed_fields[:phone],
      contact_email: submission.contact&.email.presence || parsed_fields[:email],
      lead_quality: item&.lead_quality,
      lead_score: item&.lead_score,
      lead_objection: item&.lead_objection,
      lead_observation: item&.lead_observation,
      available_stages: item && PipelineStage.where(pipeline_id: item.pipeline_id).order(:position).map { |s| { id: s.id, name: s.name } }
    )
  end
end
