# Guarda o "desenho" completo do horário de funcionamento (inclusive blocos
# desativados) fora do iFood — a API deles não tem conceito de "desativado,
# mas guardado pra religar depois": um shift só existe se estiver na lista
# enviada no PUT (confirmado: mandar enabled: false num shift é ignorado,
# a API sempre devolve enabled: true). Sem isso, desativar um bloco = apagar
# de vez, forçando redigitar tudo quando o usuário quiser reabrir.
# Reaproveita o GlobalConfig/InstallationConfig já usado pras outras
# credenciais do iFood (instalação única, sem necessidade de tabela nova).
module Ifood
  class OpeningHoursDraft
    KEY = 'IFOOD_OPENING_HOURS_DRAFT'.freeze

    def self.load
      raw = GlobalConfigService.load(KEY, nil)
      raw.present? ? JSON.parse(raw) : []
    rescue JSON::ParserError
      []
    end

    def self.save(shifts)
      GlobalConfig.set(KEY, shifts.to_json)
    end
  end
end
