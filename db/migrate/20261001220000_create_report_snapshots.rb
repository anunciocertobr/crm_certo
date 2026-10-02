class CreateReportSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :report_snapshots, id: :uuid do |t|
      t.string :token, null: false
      t.string :report_type, null: false
      t.string :title
      t.jsonb :data, null: false, default: {}
      t.datetime :expires_at, null: false
      # revoked_at preenchido = link invalidado na mão, antes de expirar.
      t.datetime :revoked_at
      t.uuid :created_by_id

      t.timestamps
    end
    add_index :report_snapshots, :token, unique: true
    add_index :report_snapshots, :expires_at
  end
end
