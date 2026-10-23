# frozen_string_literal: true

# Um registro por CICLO (ocorrência) de um ServiceInvoiceSchedule — criado
# quando chega a hora de notificar, e fechado quando a pessoa confirma,
# recusa, ou não responde a tempo. Nunca existe emissão sem passar por um
# registro aqui com status 'confirmed'.
class CreateServiceInvoiceScheduleConfirmations < ActiveRecord::Migration[7.1]
  def change
    create_table :service_invoice_schedule_confirmations, id: :uuid do |t|
      t.references :service_invoice_schedule, null: false, type: :uuid, foreign_key: true
      t.datetime :scheduled_for, null: false

      t.string :status, null: false, default: 'pending_notification'
      # pending_notification -> notified -> [confirmed | declined | no_response]
      #                                  -> awaiting_edit_field -> awaiting_edit_confirmation -> confirmed
      # confirmed -> emitted | error

      # Mudanças válidas só pra esta ocorrência (ex.: {"valor_servicos"=>"600.00"})
      # — nunca altera o template do ServiceInvoiceSchedule.
      t.jsonb :overrides, null: false, default: {}

      # {"whatsapp"=>"<conversation_id>", "telegram"=>"<conversation_id>"} —
      # guarda a conversa de cada canal que recebeu a notificação, pro
      # listener achar de volta qual confirmação uma mensagem respondida
      # pertence (via Conversation#custom_attributes).
      t.jsonb :conversation_ids, null: false, default: {}

      # Setado quando status=awaiting_edit_field: qual campo a pessoa
      # escolheu editar, aguardando o valor novo na próxima mensagem.
      t.string :pending_edit_field

      t.datetime :notified_at
      t.datetime :responded_at

      t.references :service_invoice, null: true, type: :uuid, foreign_key: true
      t.text :erro_mensagem

      t.timestamps
    end

    add_index :service_invoice_schedule_confirmations, %i[service_invoice_schedule_id scheduled_for],
              unique: true, name: 'idx_siv_schedule_confirmations_ciclo'
    add_index :service_invoice_schedule_confirmations, :status
  end
end
