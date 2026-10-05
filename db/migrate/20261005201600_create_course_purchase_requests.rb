class CreateCoursePurchaseRequests < ActiveRecord::Migration[7.1]
  def change
    # Compra aprovada na mao: o pedido fica pending, o aluno paga por fora (PIX
    # do criador) e quem decide libera o acesso approvando. Nao ha gateway de
    # pagamento no CRM, entao nao ha payment_id de fora para guardar.
    create_table :course_purchase_requests, id: :uuid do |t|
      t.uuid :course_id, null: false
      t.uuid :user_id, null: false
      t.integer :price_cents, null: false
      t.string :currency, null: false, default: 'BRL'
      t.string :status, null: false, default: 'pending'
      t.string :payment_method, null: false, default: 'pix'
      t.text :note

      t.uuid :decided_by_id
      t.datetime :decided_at

      t.timestamps
    end

    add_index :course_purchase_requests, %i[course_id status]
    add_index :course_purchase_requests, :user_id
    # Um pedido pendente por aluno/curso: pedir duas vezes antes da aprovacao
    # reutiliza a linha existente em vez de duplicar a fila do criador.
    add_index :course_purchase_requests, %i[course_id user_id],
              unique: true, where: "status = 'pending'", name: 'index_course_purchase_requests_pending_unique'
  end
end
