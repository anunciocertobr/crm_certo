# Preferência de notificação por WhatsApp pra leads de um formulário Meta
# específico (ver Meta::LeadAds::WhatsappNotifierService). Sem registro pra um
# form_id, a notificação cai no padrão da conta (GlobalConfigService, config
# type 'meta_leads_notify' — ver Api::V1::Admin::AppConfigsController).
class MetaLeadNotificationSetting < ApplicationRecord
  belongs_to :inbox, optional: true

  validates :form_id, presence: true, uniqueness: true
end
