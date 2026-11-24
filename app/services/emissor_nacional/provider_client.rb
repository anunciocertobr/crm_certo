# frozen_string_literal: true

# Liga o Emissor Nacional (Sefin Nacional NFS-e, obrigatório pro Simples
# Nacional desde 01/11/2026) ao fluxo de emissão do CRM, no mesmo contrato
# do Guarulhos::Client (NotaFiscal::ProviderClient): emitir,
# consultar_situacao, cancelar. Selecionado por
# FiscalEstablishment#provider_key = 'emissor_nacional'.
#
# Ambiente: FiscalEstablishment#ambiente 'producao' -> tpAmb 1
# (sefin.nfse.gov.br); qualquer outro -> tpAmb 2 (produção restrita).
#
# Onde cada dado da NFS-e nacional fica no ServiceInvoice (sem migration):
#   codigo_verificacao -> chave de acesso (50 dígitos)
#   protocolo          -> Id da DPS (consulta GET /dps/{id} se a resposta se perder)
#   numero_nfse        -> nNFSe
#   xml_envio/retorno  -> DPS assinada / XML da NFS-e
#
# A emissão é síncrona (201 já traz a NFS-e). Se a resposta não chegar
# (timeout/erro de rede), a nota fica 'processing' e o PollStatusJob
# pergunta ao Sefin pelo Id da DPS — nunca reenvia às cegas, pra não gerar
# NFS-e duplicada.
module EmissorNacional
  class ProviderClient < NotaFiscal::ProviderClient
    class Error < NotaFiscal::ProviderClient::Error; end

    # Depois disso sem NFS-e pra DPS, a tentativa é dada como perdida.
    PROCESSING_TIMEOUT = 30.minutes

    def emitir(invoice)
      dps_xml, result = client.emitir_dps(invoice, tp_amb: tp_amb)
      invoice.xml_envio = dps_xml
      invoice.protocolo = client.dps_id_for(invoice)
      apply_emissao(invoice, result)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      # Não dá pra saber se a NFS-e foi gerada: consulta depois pelo Id da DPS.
      invoice.protocolo ||= client.dps_id_for(invoice)
      invoice.status = 'processing'
      invoice.erro_mensagem = "Sem resposta do Emissor Nacional (#{e.class}); consultando pela DPS."
      invoice.save!
      invoice
    rescue EmissorNacional::Client::Error => e
      invoice.status = 'error'
      invoice.erro_mensagem = e.message
      invoice.save!
      raise Error, e.message
    end

    def consultar_situacao(invoice)
      return invoice unless invoice.status == 'processing' && invoice.protocolo.present?

      chave = client.chave_por_dps(invoice.protocolo, tp_amb: tp_amb)
      if chave
        authorize!(invoice, chave, client.consultar_nfse(chave, tp_amb: tp_amb))
      elsif invoice.created_at < PROCESSING_TIMEOUT.ago
        invoice.status = 'error'
        invoice.erro_mensagem = 'O Emissor Nacional não gerou NFS-e para esta DPS.'
        invoice.save!
      end
      invoice
    rescue EmissorNacional::Client::Error => e
      raise Error, "Falha ao consultar NFS-e no Emissor Nacional: #{e.message}"
    end

    def cancelar(invoice)
      chave = invoice.codigo_verificacao.to_s
      raise Error, 'NFS-e sem chave de acesso — só nota autorizada pode ser cancelada' unless chave.match?(/\A\d{50}\z/)

      result = client.cancelar_nfse(chave, tp_amb: tp_amb)
      raise Error, "Emissor Nacional recusou o cancelamento: #{format_erros(result.error)}" unless result.success

      invoice.status = 'cancelled'
      invoice.erro_mensagem = nil
      invoice.save!
      invoice
    end

    private

    def client
      @client ||= EmissorNacional::Client.new(establishment: @establishment)
    end

    def tp_amb
      @establishment.ambiente == 'producao' ? '1' : '2'
    end

    def apply_emissao(invoice, result)
      if result.success
        authorize!(invoice, result.data['chaveAcesso'], result.data['nfseXml'])
      else
        invoice.status = 'error'
        invoice.erro_mensagem = format_erros(result.error)
        invoice.xml_retorno = result.raw_response
        invoice.save!
      end
      invoice
    end

    def authorize!(invoice, chave, nfse_xml)
      doc = Nokogiri::XML(nfse_xml.to_s)
      invoice.status = 'authorized'
      invoice.codigo_verificacao = chave
      invoice.numero_nfse = doc.at_xpath("//*[local-name()='infNFSe']/*[local-name()='nNFSe']")&.text
      invoice.xml_retorno = nfse_xml
      invoice.erro_mensagem = nil
      invoice.save!
    end

    # erros vem como [{"Codigo"=>"E0039","Descricao"=>"...","Complemento"=>"..."}]
    def format_erros(erros)
      Array.wrap(erros).map do |e|
        next e.to_s unless e.is_a?(Hash)

        codigo = e['Codigo'] || e['codigo']
        desc = [e['Descricao'] || e['descricao'], e['Complemento'] || e['complemento']].compact.join(' — ')
        "[#{codigo}] #{desc}"
      end.join(' | ').presence || 'Erro desconhecido no Emissor Nacional'
    end
  end
end
