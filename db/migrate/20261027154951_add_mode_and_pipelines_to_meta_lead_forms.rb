class AddModeAndPipelinesToMetaLeadForms < ActiveRecord::Migration[7.1]
  def up
    add_column :meta_lead_forms, :mode, :string, null: false, default: 'pipeline'

    create_table :meta_lead_form_pipelines, id: :uuid do |t|
      t.uuid :meta_lead_form_id, null: false
      t.uuid :pipeline_id, null: false
      t.uuid :pipeline_stage_id, null: false

      t.timestamps
    end
    add_index :meta_lead_form_pipelines, :meta_lead_form_id
    add_foreign_key :meta_lead_form_pipelines, :meta_lead_forms, on_delete: :cascade
    add_foreign_key :meta_lead_form_pipelines, :pipelines
    add_foreign_key :meta_lead_form_pipelines, :pipeline_stages

    # Migra cada mapeamento existente (1 pipeline/estágio direto na coluna)
    # pra 1 linha na tabela nova — nenhum formulário já mapeado perde o
    # destino quando o código passa a ler só meta_lead_form_pipelines.
    execute <<~SQL.squish
      INSERT INTO meta_lead_form_pipelines (id, meta_lead_form_id, pipeline_id, pipeline_stage_id, created_at, updated_at)
      SELECT gen_random_uuid(), id, pipeline_id, pipeline_stage_id, created_at, updated_at
      FROM meta_lead_forms
      WHERE pipeline_id IS NOT NULL AND pipeline_stage_id IS NOT NULL
    SQL

    change_column_null :meta_lead_forms, :pipeline_id, true
    change_column_null :meta_lead_forms, :pipeline_stage_id, true
  end

  def down
    change_column_null :meta_lead_forms, :pipeline_id, false
    change_column_null :meta_lead_forms, :pipeline_stage_id, false
    drop_table :meta_lead_form_pipelines
    remove_column :meta_lead_forms, :mode
  end
end
