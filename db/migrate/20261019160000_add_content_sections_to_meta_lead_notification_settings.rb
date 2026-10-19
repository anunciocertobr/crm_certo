class AddContentSectionsToMetaLeadNotificationSettings < ActiveRecord::Migration[7.1]
  def change
    # Lista (JSON array) das seções que devem ir na mensagem de notificação do
    # lead — ver Meta::LeadAds::WhatsappNotifierService::CONTENT_SECTIONS.
    # Nil (nunca configurado) = envia todas as seções (comportamento anterior a
    # esta coluna existir); array (mesmo vazio) = respeita exatamente o que foi
    # escolhido no front. Fica por formulário, igual ao resto do setting.
    add_column :meta_lead_notification_settings, :content_sections, :jsonb
  end
end
