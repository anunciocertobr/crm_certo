# frozen_string_literal: true

# Perfil fiscal pra emissão de NF-e 55 (mercadoria/e-commerce) e NFC-e 65
# (balcão/delivery) — independente de FiscalEstablishment, que é só pra
# NFS-e municipal (Guarulhos). NF-e/NFC-e são de âmbito ESTADUAL (SEFAZ),
# não municipal: não faz sentido reaproveitar municipio_ibge_code/
# inscricao_municipal daquele model pra isso.
class CreateGoodsFiscalProfiles < ActiveRecord::Migration[7.1]
  def change
    create_table :goods_fiscal_profiles, id: :uuid do |t|
      t.string :cnpj, null: false
      t.string :razao_social, null: false
      t.string :nome_fantasia
      t.string :uf, null: false, limit: 2
      t.string :inscricao_estadual, null: false
      # Código de Regime Tributário: 1 Simples Nacional, 2 Simples excesso
      # sublimite, 3 Regime Normal — decide CST (normal) vs CSOSN (Simples).
      t.string :crt, null: false, default: '1'
      t.string :ambiente, null: false, default: 'homologacao'

      # Mesmo padrão de certificado A1 do FiscalEstablishment (Active Record
      # Encryption), mas um registro separado — cada âmbito fiscal com o seu.
      t.text :certificate_content_encrypted
      t.text :certificate_password_encrypted
      t.date :certificate_expires_at

      # CSC (Código de Segurança do Contribuinte) — exigido pro QR Code da
      # NFC-e. Só existe depois que a SEFAZ do estado libera credenciamento.
      t.text :csc_id_encrypted
      t.text :csc_token_encrypted

      # Provedor certificado que vai de fato transmitir pra SEFAZ (eNotas,
      # Focus NFe, PlugNotas...) — nil enquanto não for contratado. Ver
      # GoodsInvoices::UnconfiguredProviderClient.
      t.string :provider_key
      t.text :provider_api_key_encrypted

      t.string :serie_nfe, null: false, default: '1'
      t.integer :numero_nfe_atual, null: false, default: 0
      t.string :serie_nfce, null: false, default: '1'
      t.integer :numero_nfce_atual, null: false, default: 0

      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :goods_fiscal_profiles, :cnpj, unique: true
  end
end
