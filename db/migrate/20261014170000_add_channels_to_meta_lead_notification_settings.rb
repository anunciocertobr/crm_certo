class AddChannelsToMetaLeadNotificationSettings < ActiveRecord::Migration[7.1]
  def change
    # Aditivo: as colunas antigas inbox_id/whatsapp_number continuam existindo
    # e sendo lidas como fallback (1 canal legado) enquanto channels estiver
    # vazio, pra não quebrar quem já tinha notificação configurada antes
    # desta migration. Pedido do usuário: poder notificar vários canais/
    # números pro mesmo formulário (botão "+" no front), não só um.
    add_column :meta_lead_notification_settings, :channels, :jsonb, null: false, default: []
  end
end
