class AddLeadQualificationToPipelineItems < ActiveRecord::Migration[7.1]
  def change
    # Qualificação manual do lead (botão "Qualificar Lead" no Kanban) —
    # campos próprios em vez de `custom_fields` (jsonb) porque viram sinal
    # pra fora (Meta::ConversionsApiService) e precisam ser filtráveis/
    # indexáveis (ex.: listar só leads "alta" no board), diferente de
    # custom_fields que é só exibição.
    add_column :pipeline_items, :lead_quality, :string
    add_column :pipeline_items, :lead_score, :integer
    add_column :pipeline_items, :lead_objection, :text
    add_column :pipeline_items, :lead_observation, :text
    add_column :pipeline_items, :lead_qualified_at, :datetime

    add_index :pipeline_items, :lead_quality
  end
end
