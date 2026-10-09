# Preferência de notificação por WhatsApp por formulário Meta — ver
# MetaLeadNotificationSetting e Meta::LeadAds::WhatsappNotifierService.
# Diferente de MetaLeadFormsController (que exige pipeline/estágio pra
# mapear no CRM), aqui o form_id é a própria chave: não precisa o formulário
# estar mapeado no CRM pra ter uma preferência de notificação.
class Api::V1::Admin::MetaLeadNotificationSettingsController < Api::V1::Admin::BaseController
  # GET /meta_lead_notification_settings?form_ids[]=...&form_ids[]=...
  # Devolve só os registros que existem — form_id sem registro usa o padrão
  # da conta (config 'meta_leads_notify'), o front trata a ausência como isso.
  def index
    form_ids = Array(params[:form_ids])
    settings = form_ids.present? ? MetaLeadNotificationSetting.where(form_id: form_ids) : MetaLeadNotificationSetting.all
    render json: { success: true, data: settings.map { |s| serialize(s) } }
  end

  # PUT /meta_lead_notification_settings/:form_id (form_id vem na URL, não é o id da linha)
  def upsert
    setting = MetaLeadNotificationSetting.find_or_initialize_by(form_id: params[:form_id])
    if setting.update(meta_lead_notification_setting_params)
      render json: { success: true, data: serialize(setting) }
    else
      render json: { success: false, message: setting.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def destroy
    MetaLeadNotificationSetting.find_by(form_id: params[:form_id])&.destroy
    render json: { success: true }
  end

  private

  def meta_lead_notification_setting_params
    params.permit(:page_id, :form_name, :enabled, :inbox_id, :whatsapp_number)
  end

  def serialize(setting)
    {
      form_id: setting.form_id,
      page_id: setting.page_id,
      form_name: setting.form_name,
      enabled: setting.enabled,
      inbox_id: setting.inbox_id,
      whatsapp_number: setting.whatsapp_number
    }
  end
end
