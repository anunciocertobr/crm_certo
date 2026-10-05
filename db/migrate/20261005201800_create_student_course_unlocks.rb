class CreateStudentCourseUnlocks < ActiveRecord::Migration[7.1]
  def change
    # Senha do aluno para entrar na area de cursos ("Netflix"). Uma por usuario.
    # Nao ha bcrypt no bundle, entao o digest e PBKDF2-HMAC-SHA256 (stdlib).
    create_table :student_course_unlocks, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.string :password_digest, null: false
      t.integer :failed_attempts, null: false, default: 0
      t.datetime :last_unlocked_at
      t.timestamps
    end

    add_index :student_course_unlocks, :user_id, unique: true
  end
end
