class CreateTiktokUploads < ActiveRecord::Migration[7.1]
  def change
    create_table :tiktok_uploads, id: :uuid, if_not_exists: true do |t|
      t.uuid :created_by, null: false
      t.string :title, null: false
      # Sempre forçado pra um valor privado (ver Tiktok::UploadService) — app
      # ainda não aprovado pela TikTok (App Review) recusa qualquer post que
      # não seja privado ("unaudited_client_can_only_post_to_private_accounts").
      # Guardado aqui só pra registro, não é escolha do usuário na tela ainda.
      t.string :privacy_level
      t.string :status, null: false, default: 'pending'
      t.text :error_message
      t.string :external_post_id

      t.timestamps
    end

    add_index :tiktok_uploads, :status, if_not_exists: true
    add_index :tiktok_uploads, :created_by, if_not_exists: true
  end
end
