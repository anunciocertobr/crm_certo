# Padrão por PÁGINA do Meta Lead Ads (pipelines + canais de notificação +
# dataset(s) sugeridos pro Conversion Leads) — ver MetaLeadPageSetting.
# page_id é a própria chave (igual MetaLeadNotificationSettingsController),
# não precisa nenhuma página estar "mapeada" antes de ter um padrão.
class Api::V1::Admin::MetaLeadPageSettingsController < Api::V1::Admin::BaseController
  # GET /meta_lead_page_settings/:page_id — nunca 404: página sem padrão
  # configurado ainda devolve tudo vazio, o front trata como "sem padrão".
  def show
    setting = MetaLeadPageSetting.find_by(page_id: params[:page_id])
    render json: { success: true, data: setting ? serialize(setting) : empty_payload }
  end

  # PUT /meta_lead_page_settings/:page_id
  def upsert
    setting = MetaLeadPageSetting.find_or_initialize_by(page_id: params[:page_id])
    setting.assign_attributes(meta_lead_page_setting_params)
    assign_pipelines(setting)
    if setting.save
      render json: { success: true, data: serialize(setting.reload) }
    else
      render json: { success: false, message: setting.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  private

  def assign_pipelines(setting)
    return unless params.key?(:pipelines)

    setting.meta_lead_page_pipelines.destroy_all if setting.persisted?
    Array(params[:pipelines]).each do |p|
      setting.meta_lead_page_pipelines.build(pipeline_id: p[:pipeline_id], pipeline_stage_id: p[:pipeline_stage_id])
    end
  end

  def meta_lead_page_setting_params
    params.permit(channels: [:inbox_id, :whatsapp_number, :group_jid, :group_name], dataset_ids: [])
  end

  def empty_payload
    { page_id: params[:page_id], channels: [], dataset_ids: [], pipelines: [] }
  end

  def serialize(setting)
    {
      page_id: setting.page_id,
      channels: setting.channels,
      dataset_ids: setting.dataset_ids,
      pipelines: setting.meta_lead_page_pipelines.map do |p|
        {
          pipeline_id: p.pipeline_id,
          pipeline_stage_id: p.pipeline_stage_id,
          pipeline_name: p.pipeline&.name,
          pipeline_stage_name: p.pipeline_stage&.name
        }
      end
    }
  end
end
