class CreateCreatorFollows < ActiveRecord::Migration[7.1]
  def change
    create_table :creator_follows, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.uuid :creator_profile_id, null: false
      t.timestamps
    end

    add_index :creator_follows, %i[user_id creator_profile_id], unique: true
    add_index :creator_follows, :creator_profile_id
  end
end
