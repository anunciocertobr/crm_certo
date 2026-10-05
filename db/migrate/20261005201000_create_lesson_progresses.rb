class CreateLessonProgresses < ActiveRecord::Migration[7.1]
  def change
    # Uma linha por (inscricao, aula). Guarda onde a pessoa parou, para
    # "continuar assistindo" retomar no segundo exato, e se terminou.
    create_table :lesson_progresses, id: :uuid do |t|
      t.uuid :course_enrollment_id, null: false
      t.uuid :course_lesson_id, null: false
      t.integer :position_seconds, null: false, default: 0
      t.boolean :completed, null: false, default: false
      t.datetime :completed_at
      t.datetime :last_watched_at, null: false

      t.timestamps
    end

    add_index :lesson_progresses, %i[course_enrollment_id course_lesson_id], unique: true,
              name: 'index_lesson_progresses_on_enrollment_and_lesson'
    add_index :lesson_progresses, :course_lesson_id
  end
end
