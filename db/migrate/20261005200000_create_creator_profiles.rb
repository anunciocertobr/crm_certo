class CreateCreatorProfiles < ActiveRecord::Migration[7.1]
  def change
    # Perfil de venda de cursos. Uma linha por usuário que vende: o catálogo é
    # global (marketplace), mas quem publica é sempre alguém identified pelo
    # user_id do evo-auth-service. Sem FK: `users` é tabela do outro serviço e
    # o usuario pode ser removido la sem que o perfil cascade aqui.
    create_table :creator_profiles, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.string :slug, null: false
      t.string :display_name, null: false
      t.string :headline
      t.text :bio
      t.string :avatar_url
      t.string :banner_url
      t.string :whatsapp
      # Chave PIX mostrada ao aluno na compra manual (nao ha gateway no CRM).
      t.string :pix_key
      t.boolean :is_published, null: false, default: false
      t.datetime :published_at
      t.integer :courses_count, null: false, default: 0
      t.integer :followers_count, null: false, default: 0
      t.integer :students_count, null: false, default: 0

      t.timestamps
    end

    add_index :creator_profiles, :user_id, unique: true
    add_index :creator_profiles, :slug, unique: true
    add_index :creator_profiles, :is_published
  end
end