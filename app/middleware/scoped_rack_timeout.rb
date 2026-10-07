# Dá um timeout maior só pras rotas de insights/business_managers da Meta
# (podem levar bem mais que o padrão por causa de paginação da Graph API e
# de dias de servidor lento — ver incidente 2026-10-07), sem mexer no
# timeout do resto do sistema.
#
# `rack-timeout` 0.6.3 não tem NENHUM jeito suportado de variar o timeout
# por request: `service_timeout` é um atributo fixo da instância do
# middleware, lido uma única vez no boot a partir de
# RACK_TIMEOUT_SERVICE_TIMEOUT (`lib/rack/timeout/core.rb`). Uma tentativa
# anterior setava `env['rack-timeout.timeout']` num `before_action` do
# controller — isso é um no-op: nenhum código da gem lê essa chave, e o
# timeout real continuava 15s mesmo depois desse "fix" (confirmado ao vivo
# em 2026-10-07: a request de "posicionamento" de um mês inteiro ainda deu
# 500 em ~15s). A única forma real de diferenciar por rota é ter duas
# instâncias de Rack::Timeout com configs diferentes e decidir qual delas
# processa a request ANTES de chamar a aplicação — é o que esta classe faz.
class ScopedRackTimeout
  EXTENDED_PATTERN = %r{/meta_ads/(insights|business_managers)(?:/|\z|\?)}.freeze

  def initialize(app, default_timeout:, extended_timeout:)
    @default  = Rack::Timeout.new(app, service_timeout: default_timeout)
    @extended = Rack::Timeout.new(app, service_timeout: extended_timeout)
  end

  def call(env)
    path = env['PATH_INFO'].to_s
    (path.match?(EXTENDED_PATTERN) ? @extended : @default).call(env)
  end
end
