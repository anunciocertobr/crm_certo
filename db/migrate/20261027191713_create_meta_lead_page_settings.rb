class CreateMetaLeadPageSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :meta_lead_page_settings, id: :uuid do |t|
      t.string :page_id, null: false
      # channels: mesma forma de MetaLeadNotificationSetting#channels
      # ([{inbox_id, whatsapp_number} | {inbox_id, group_jid, group_name}]) —
      # padrão de notificação pra TODOS os formulários desta Página.
      t.jsonb :channels, null: false, default: []
      # dataset_ids: datasets do Conversion Leads que pré-preenchem o envio
      # manual (ver Meta::ConversionsApiCrmService#send_manual_event) — só
      # um valor-padrão de conveniência, nunca somado automaticamente, o
      # usuário pode trocar na hora do envio.
      t.jsonb :dataset_ids, null: false, default: []

      t.timestamps
    end
    add_index :meta_lead_page_settings, :page_id, unique: true

    create_table :meta_lead_page_pipelines, id: :uuid do |t|
      t.uuid :meta_lead_page_setting_id, null: false
      t.uuid :pipeline_id, null: false
      t.uuid :pipeline_stage_id, null: false

      t.timestamps
    end
    add_index :meta_lead_page_pipelines, :meta_lead_page_setting_id
    add_foreign_key :meta_lead_page_pipelines, :meta_lead_page_settings, on_delete: :cascade
    add_foreign_key :meta_lead_page_pipelines, :pipelines
    add_foreign_key :meta_lead_page_pipelines, :pipeline_stages
  end
end
