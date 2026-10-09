class CreateMetaLeadNotificationSettings < ActiveRecord::Migration[7.1]
  def change
    # Independente de MetaLeadForm (que exige pipeline/estágio pra mapear um
    # lead no CRM) — notificar por WhatsApp é uma preferência à parte, que
    # precisa funcionar mesmo pra formulário ainda não mapeado no CRM.
    create_table :meta_lead_notification_settings, id: :uuid do |t|
      t.string :page_id
      t.string :form_id, null: false
      t.string :form_name
      t.boolean :enabled, null: false, default: true
      t.uuid :inbox_id
      t.string :whatsapp_number

      t.timestamps
    end
    add_index :meta_lead_notification_settings, :form_id, unique: true
    add_foreign_key :meta_lead_notification_settings, :inboxes, on_delete: :nullify

    # Evita reenviar a notificação se a submission for reprocessada (ver
    # Meta::LeadAds::ImportService.reprocess).
    add_column :meta_lead_submissions, :notified_whatsapp_at, :datetime
  end
end
