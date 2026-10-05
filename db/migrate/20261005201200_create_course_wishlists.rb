class CreateCourseWishlists < ActiveRecord::Migration[7.1]
  def change
    # Lista de desejo. Um item so por (aluno, curso): clicar duas vezes no
    # coracao nao pode criar duplicata nem falhar por unique index.
    create_table :course_wishlists, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.uuid :course_id, null: false
      t.timestamps
    end

    add_index :course_wishlists, %i[user_id course_id], unique: true
    add_index :course_wishlists, :course_id
  end
end
