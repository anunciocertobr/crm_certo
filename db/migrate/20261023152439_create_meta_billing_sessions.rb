# frozen_string_literal: true

# Sessão compartilhada única (singleton) do Facebook usada pela automação
# de cobrança de saldo pré-pago do Meta Ads (aba Pagamentos). Não existe
# API pública pra gerar PIX/boleto de recarga — a automação precisa de uma
# sessão de navegador logada de verdade, cujos cookies ficam cifrados
# aqui. `lock_key` garante no banco que só existe 1 linha (índice único em
# valor fixo), mesmo padrão simples de singleton table do Postgres.
class CreateMetaBillingSessions < ActiveRecord::Migration[7.1]
  def change
    create_table :meta_billing_sessions, id: :uuid do |t|
      t.string :lock_key, null: false, default: 'singleton'
      t.string :status, null: false, default: 'idle'
      # Export do Cookie-Editor (JSON) pros cookies de facebook.com,
      # cifrado via ActiveRecord::Encryption — nunca guardamos email/senha
      # reais, só a sessão já autenticada que um humano importou.
      t.text :cookies_encrypted
      t.datetime :cookies_imported_at
      t.datetime :last_verified_at
      t.text :last_error

      t.timestamps
    end

    add_index :meta_billing_sessions, :lock_key, unique: true
  end
end
