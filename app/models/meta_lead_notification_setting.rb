# Preferência de notificação por WhatsApp pra leads de um formulário Meta
# específico (ver Meta::LeadAds::WhatsappNotifierService). Sem registro pra um
# form_id, a notificação cai no padrão da conta (GlobalConfigService, config
# type 'meta_leads_notify' — ver Api::V1::Admin::AppConfigsController).
class MetaLeadNotificationSetting < ApplicationRecord
  belongs_to :inbox, optional: true

  validates :form_id, presence: true, uniqueness: true

  # channels: [{ "inbox_id" => uuid, "whatsapp_number" => string }, ...] —
  # suporta notificar mais de um canal/número pro mesmo formulário. Antes só
  # existia inbox_id/whatsapp_number (um par só); essas duas colunas continuam
  # existindo e funcionando como o canal legado de quem configurou antes da
  # coluna channels existir, pra não quebrar notificação já configurada.
  def effective_channels
    return channels if channels.present?
    return [] unless inbox_id.present? && whatsapp_number.present?

    [{ 'inbox_id' => inbox_id, 'whatsapp_number' => whatsapp_number }]
  end
end
