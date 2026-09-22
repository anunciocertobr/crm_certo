# Chaves da criptografia nativa do Rails (Active Record Encryption) — usada
# pela primeira vez neste repo em FiscalEstablishment (certificado digital +
# senha do certificado, campos sensíveis demais pro Fernet do
# InstallationConfig, que é pensado pra valores pequenos em cache Redis).
#
# Em produção, definir ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY/DETERMINISTIC_KEY/
# KEY_DERIVATION_SALT no ambiente (mesmo nome que `bin/rails db:encryption:init`
# sugere). Sem essas variáveis, deriva chaves determinísticas a partir de
# secret_key_base — mesma estratégia de fallback já usada pelo Fernet em
# InstallationConfig (`resolve_encryption_key`) — pra não quebrar em dev/test.
Rails.application.config.active_record.encryption.primary_key =
  ENV.fetch('ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY') do
    ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                               .generate_key('active_record_encryption_primary_key_v1', 32)
                               .unpack1('H*')
  end

Rails.application.config.active_record.encryption.deterministic_key =
  ENV.fetch('ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY') do
    ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                               .generate_key('active_record_encryption_deterministic_key_v1', 32)
                               .unpack1('H*')
  end

Rails.application.config.active_record.encryption.key_derivation_salt =
  ENV.fetch('ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT') do
    ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                               .generate_key('active_record_encryption_key_derivation_salt_v1', 32)
                               .unpack1('H*')
  end
