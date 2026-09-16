# Listas reutilizáveis de itens de direcionamento detalhado da Meta
# (interesses/comportamentos/dados demográficos), montadas manualmente pelo
# usuário (ex: lista "Medicina" com Médico, Veterinário, Estudante de
# medicina, Enfermagem) — não existe no Graph API um objeto assim, só o
# "flexible_spec" solto de uma campanha ou o "Saved Audience" completo (que
# já exige geo/idade/etc). Isso guarda só o recorte de itens, pra depois
# montar um público puxando um subconjunto qualquer da lista salva.
class CreateTargetingLists < ActiveRecord::Migration[7.1]
  def change
    create_table :targeting_lists, id: :uuid, default: -> { 'gen_random_uuid()' }, if_not_exists: true do |t|
      t.string :name, null: false
      t.jsonb :items, default: [], null: false

      t.timestamps
    end

    add_index :targeting_lists, :name, unique: true, if_not_exists: true
  end
end
