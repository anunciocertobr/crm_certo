# Contrato comum que cada cliente municipal de NFS-e implementa
# (Guarulhos::Client é o primeiro; São Paulo/Campinas/Hortolândia seguem o
# mesmo formato em fases futuras). Ruby não exige herança pra duck typing,
# mas uma classe-base explícita documenta o contrato num lugar só e dá um
# guard-rail (`NotImplementedError`) caso um client novo esqueça um método.
module NotaFiscal
  class ProviderClient
    def initialize(fiscal_establishment)
      @establishment = fiscal_establishment
    end

    # Envia o RPS pra autorização. Quem chama usa o retorno pra atualizar
    # protocolo/status/xml_envio/xml_retorno do ServiceInvoice.
    def emitir(invoice)
      raise NotImplementedError
    end

    # Consulta o status de processamento (por protocolo, nos municípios
    # assíncronos, ou por número de RPS nos que retornam na hora mas ainda
    # pedem uma consulta de confirmação).
    def consultar_situacao(invoice)
      raise NotImplementedError
    end

    def cancelar(invoice)
      raise NotImplementedError
    end
  end
end
