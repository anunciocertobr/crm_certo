class CreateCourseModules < ActiveRecord::Migration[7.1]
  def change
    create_table :course_modules, id: :uuid do |t|
      t.uuid :course_id, null: false
      t.string :title, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    add_index :course_modules, :course_id
    add_index :course_modules, %i[course_id position]
  end
end
