require 'rack-timeout'
# Autoload do Zeitwerk ainda não está pronto nesta fase do boot (mesmo
# `app/middleware` estando em eager_load_paths) — precisa de require
# explícito, mesmo padrão já usado em facebook_webhook_logger.rb.
require_relative '../../app/middleware/scoped_rack_timeout'

# Reduce noise by filtering state=ready and state=completed which are logged at INFO level
Rails.application.config.after_initialize do
  Rack::Timeout::Logger.level = Logger::ERROR
end

# `require 'rack-timeout'` acima já registrou o Railtie da gem, que insere a
# classe `Rack::Timeout` (15s fixo pra toda rota) no stack de middleware.
# Tiramos essa instância e colocamos `ScopedRackTimeout` no lugar, que usa
# 45s só pra insights/business_managers da Meta — ver
# app/middleware/scoped_rack_timeout.rb pro motivo de isso não dar pra fazer
# com env['rack-timeout.timeout'] num before_action do controller (tentativa
# anterior, não funcionava: a gem não lê essa chave).
Rails.application.config.middleware.delete(Rack::Timeout)

if defined?(ActionDispatch::RequestId)
  Rails.application.config.middleware.insert_after(
    ActionDispatch::RequestId, ScopedRackTimeout, default_timeout: 15, extended_timeout: 45
  )
else
  Rails.application.config.middleware.insert_before(
    Rack::Runtime, ScopedRackTimeout, default_timeout: 15, extended_timeout: 45
  )
end
