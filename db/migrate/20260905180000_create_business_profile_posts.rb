class CreateBusinessProfilePosts < ActiveRecord::Migration[7.1]
  def change
    create_table :business_profile_posts, id: :uuid, if_not_exists: true do |t|
      t.uuid :created_by, null: false
      t.string :account_name, null: false
      t.string :location_id, null: false
      t.string :location_title
      t.text :summary, null: false
      t.string :cta_action_type
      t.string :cta_url
      t.string :status, null: false, default: 'pending'
      t.text :error_message
      t.string :external_post_name

      t.timestamps
    end

    add_index :business_profile_posts, :status, if_not_exists: true
    add_index :business_profile_posts, :created_by, if_not_exists: true
  end
end
