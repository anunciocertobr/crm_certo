# Client padrão de GoodsFiscalProfile enquanto nenhum provedor certificado
# (eNotas, Focus NFe, PlugNotas...) estiver contratado e configurado.
#
# Antes desta classe, a tela de Nota Fiscal (public/nota-fiscal.html)
# SIMULAVA a emissão inteira no navegador (protocolo falso, "cStat 100"
# hardcoded, sem persistir nada de verdade) — dava a impressão de que a
# nota saía, sem nunca falar com a SEFAZ. Esta classe faz o oposto: recusa
# com uma mensagem clara, pra nunca mais passar a falsa impressão de que
# uma nota foi autorizada quando não foi. A nota fica persistida com status
# `pending` e a mensagem abaixo em `erro_mensagem` — não é uma rejeição da
# SEFAZ, é só "transmissão ainda não configurada".
module GoodsInvoices
  class UnconfiguredProviderClient < ProviderClient
    MENSAGEM = 'Transmissão para a SEFAZ ainda não configurada — contrate um provedor ' \
               'certificado (eNotas, Focus NFe, PlugNotas etc.) e cadastre a chave de API ' \
               'no Perfil Fiscal antes de emitir de verdade.'

    def emitir(_invoice)
      raise Error, MENSAGEM
    end

    def consultar_situacao(_invoice)
      raise Error, MENSAGEM
    end

    def cancelar(_invoice)
      raise Error, MENSAGEM
    end
  end
end
