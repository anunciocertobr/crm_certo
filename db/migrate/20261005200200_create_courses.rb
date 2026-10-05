class CreateCourses < ActiveRecord::Migration[7.1]
  def change
    create_table :courses, id: :uuid do |t|
      t.uuid :creator_profile_id, null: false
      t.string :slug, null: false
      t.string :title, null: false
      t.string :subtitle
      t.text :description
      t.string :category
      t.string :level, null: false, default: 'iniciante'
      t.string :thumbnail_url
      # Video de vitrine (YouTube/Vimeo): o iframe do topo da página do curso.
      t.string :trailer_provider
      t.string :trailer_video_id
      t.string :trailer_url

      # Preco em centavos. 0 = gratuito (nao e "preco zero pago", e o model
      # expoe `free?`/`paid?` para a vitrine decidir a etiqueta).
      t.integer :price_cents, null: false, default: 0
      t.string :currency, null: false, default: 'BRL'

      t.string :status, null: false, default: 'draft'
      t.datetime :published_at

      # Contadores denormalizados: a tela "Netflix" lista o catalogo inteiro e
      # nao pode fazer COUNT por card.
      t.integer :lessons_count, null: false, default: 0
      t.integer :duration_seconds, null: false, default: 0
      t.integer :students_count, null: false, default: 0
      t.integer :rating_count, null: false, default: 0
      t.decimal :rating_average, precision: 3, scale: 2, null: false, default: '0.0'

      t.timestamps
    end

    add_index :courses, :creator_profile_id
    add_index :courses, :slug, unique: true
    add_index :courses, :status
    add_index :courses, :category
    add_index :courses, :published_at
  end
end