# Contrato comum pra quem transmite NF-e/NFC-e de verdade pra SEFAZ.
# Deliberadamente SEM herdar de NotaFiscal::ProviderClient (o contrato do
# NFS-e municipal) — são sistemas independentes por pedido explícito do
# usuário, mesmo repetindo a forma do contrato.
#
# Diferente do Guarulhos (webservice municipal direto, sem custo de
# terceiro), ir direto na SEFAZ de cada estado é um projeto por si só:
# WSDL/schema por UF, contingência (SVC-AN/SVC-RS), cálculo pleno de
# ICMS/ICMS-ST por estado, DANFE, QR Code da NFC-e (exige CSC credenciado
# na SEFAZ do estado). Por isso o caminho real de implementação é contratar
# um provedor certificado (eNotas, Focus NFe, PlugNotas...) que resolve
# tudo isso por uma API só — GoodsFiscalProfile#provider_key escolhe qual.
# Até isso ser contratado, GoodsFiscalProfile usa UnconfiguredProviderClient.
module GoodsInvoices
  class ProviderClient
    class Error < StandardError; end

    def initialize(fiscal_profile)
      @profile = fiscal_profile
    end

    def emitir(invoice)
      raise NotImplementedError
    end

    def consultar_situacao(invoice)
      raise NotImplementedError
    end

    def cancelar(invoice)
      raise NotImplementedError
    end
  end
end
