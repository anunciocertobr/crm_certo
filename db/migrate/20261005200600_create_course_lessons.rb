class CreateCourseLessons < ActiveRecord::Migration[7.1]
  def change
    create_table :course_lessons, id: :uuid do |t|
      t.uuid :course_module_id, null: false
      # course_id denormalizado: a vitrine e o progresso consultam por curso sem
      # passar por JOIN toda vez.
      t.uuid :course_id, null: false
      t.string :title, null: false
      t.text :description
      t.integer :position, null: false, default: 0

      # Video de fora: YouTube ou Vimeo, colado como URL. `video_id` e o que o
      # player usa para montar o embed.
      t.string :video_provider
      t.string :video_id
      t.string :video_url
      t.integer :duration_seconds, null: false, default: 0

      # Aula liberada para quem ainda nao comprou: e o "degustacao" do curso.
      t.boolean :is_preview, null: false, default: false

      t.timestamps
    end

    add_index :course_lessons, :course_module_id
    add_index :course_lessons, :course_id
    add_index :course_lessons, %i[course_module_id position]
  end
end
