class CreateCourseEnrollments < ActiveRecord::Migration[7.1]
  def change
    create_table :course_enrollments, id: :uuid do |t|
      t.uuid :course_id, null: false
      t.uuid :user_id, null: false
      t.string :status, null: false, default: 'active'
      # Como o aluno entrou: gratuito, compra aprovada ou senha do curso.
      t.string :source, null: false, default: 'free'

      t.uuid :last_lesson_id
      t.decimal :progress_percent, precision: 5, scale: 2, null: false, default: '0.0'
      t.datetime :started_at, null: false
      t.datetime :last_watched_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :course_enrollments, %i[course_id user_id], unique: true
    add_index :course_enrollments, :user_id
    add_index :course_enrollments, :last_lesson_id
    add_index :course_enrollments, :last_watched_at
  end
end
