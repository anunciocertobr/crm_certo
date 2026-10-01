class CreateMetaLeadFormsAndSubmissions < ActiveRecord::Migration[7.1]
  def change
    create_table :meta_lead_forms, id: :uuid do |t|
      t.string :page_id, null: false
      t.string :form_id, null: false
      t.string :form_name
      t.uuid :pipeline_id, null: false
      t.uuid :pipeline_stage_id, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end
    add_index :meta_lead_forms, :form_id, unique: true
    add_index :meta_lead_forms, :page_id
    add_foreign_key :meta_lead_forms, :pipelines
    add_foreign_key :meta_lead_forms, :pipeline_stages

    create_table :meta_lead_submissions, id: :uuid do |t|
      t.string :leadgen_id, null: false
      t.uuid :meta_lead_form_id
      t.string :page_id
      t.string :form_id
      t.string :ad_id
      t.string :adset_id
      t.string :campaign_id
      t.string :ad_name
      t.string :adset_name
      t.string :campaign_name
      t.jsonb :field_data, null: false, default: []
      t.datetime :lead_created_time
      t.string :status, null: false, default: 'unmapped_form'
      t.text :error_message
      t.uuid :contact_id
      t.uuid :pipeline_item_id

      t.timestamps
    end
    add_index :meta_lead_submissions, :leadgen_id, unique: true
    add_index :meta_lead_submissions, :form_id
    add_index :meta_lead_submissions, :status
    # meta_lead_submissions é histórico/auditoria — apagar um Contato (LGPD),
    # um PipelineItem ou remapear um MetaLeadForm não pode ficar bloqueado
    # por causa de uma submission antiga, daí NULLIFY em vez do RESTRICT padrão.
    add_foreign_key :meta_lead_submissions, :meta_lead_forms, on_delete: :nullify
    add_foreign_key :meta_lead_submissions, :contacts, on_delete: :nullify
    add_foreign_key :meta_lead_submissions, :pipeline_items, on_delete: :nullify
  end
end
