# frozen_string_literal: true

# Template de NFS-e recorrente: guarda os mesmos dados de um ServiceInvoice
# normal (ver service_invoices), mais a regra de recorrência e como/quando
# notificar antes de emitir de verdade. Nunca emite sozinho sem confirmação
# — ver ServiceInvoiceScheduleConfirmation, que é o ciclo de cada ocorrência.
class CreateServiceInvoiceSchedules < ActiveRecord::Migration[7.1]
  def change
    create_table :service_invoice_schedules, id: :uuid do |t|
      t.references :fiscal_establishment, null: false, type: :uuid, foreign_key: true

      t.string :tomador_nome, null: false
      t.string :tomador_cpf_cnpj, null: false
      t.string :tomador_email
      t.jsonb :tomador_endereco, null: false, default: {}
      t.text :discriminacao, null: false
      t.string :codigo_servico_municipal, null: false
      t.string :codigo_nbs, null: false
      t.string :codigo_tributacao_municipio
      t.decimal :valor_servicos, precision: 10, scale: 2, null: false
      t.decimal :valor_deducoes, precision: 10, scale: 2, null: false, default: 0
      t.decimal :aliquota_iss_pct, precision: 5, scale: 2

      t.string :recurrence_type, null: false, default: 'monthly' # once | monthly | weekly
      t.integer :day_of_month # 1-28, só pra monthly
      t.integer :day_of_week # 0 (domingo) - 6, só pra weekly
      # Data/hora completa da próxima execução — também carrega a hora do
      # dia; ServiceInvoiceSchedule#advance_next_run! soma 1 mês/semana em
      # cima dela, preservando a hora, então não existe coluna separada de
      # "horário" (evita duas fontes de verdade pra mesma informação).
      t.datetime :next_run_at, null: false

      t.integer :notify_before_value, null: false, default: 1
      t.string :notify_before_unit, null: false, default: 'days' # days | hours

      # Mais de um canal pode ficar habilitado ao mesmo tempo (pedido
      # explícito do usuário) — manda pra todos, o primeiro que responder
      # processa (ver ServiceInvoices::ScheduleNotifierService).
      t.jsonb :channels, null: false, default: []
      t.string :notify_whatsapp_number
      t.string :notify_telegram_chat_id

      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :service_invoice_schedules, :next_run_at
    add_index :service_invoice_schedules, :active
  end
end
