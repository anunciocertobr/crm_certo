# Client de NFS-e pra Guarulhos, via GissOnline (padrão ABRASF 2.04).
# Autenticação por certificado A1 (mTLS) + assinatura XMLDSig no
# InfDeclaracaoPrestacaoServico. Segue o mesmo formato de app/services/ifood/client.rb
# (Error aninhada, sem retry interno — isso fica pro job/Sidekiq).
#
# URLs de WSDL abaixo são as documentadas publicamente pro padrão GissOnline;
# confirmar contra o manual do GissOnline de Guarulhos antes do primeiro
# teste real em homologação (não dá pra validar isso sem certificado + acesso
# real, ver plano).
module Guarulhos
  class Client < NotaFiscal::ProviderClient
    class Error < StandardError; end

    WSDL_URLS = {
      'homologacao' => 'https://guarulhos.giss.com.br/homologacao/ws/nfse.wsdl',
      'producao' => 'https://guarulhos.giss.com.br/producao/ws/nfse.wsdl'
    }.freeze

    NAMESPACE = 'http://www.abrasf.org.br/nfse.xsd'.freeze

    def emitir(invoice)
      xml = sign(build_rps_xml(invoice))
      response = call_soap(:recepcionar_lote_rps, envelope_body(xml))
      apply_emissao_response(invoice, response)
    rescue Savon::Error, OpenSSL::OpenSSLError, Xmldsig::Error => e
      raise Error, "Falha ao emitir NFS-e Guarulhos: #{e.message}"
    end

    def consultar_situacao(invoice)
      response = call_soap(:consultar_situacao_lote_rps, consulta_situacao_body(invoice))
      apply_situacao_response(invoice, response)
    rescue Savon::Error => e
      raise Error, "Falha ao consultar situação NFS-e Guarulhos: #{e.message}"
    end

    def cancelar(invoice)
      xml = sign(build_cancelamento_xml(invoice))
      response = call_soap(:cancelar_nfse, envelope_body(xml))
      apply_cancelamento_response(invoice, response)
    rescue Savon::Error, OpenSSL::OpenSSLError, Xmldsig::Error => e
      raise Error, "Falha ao cancelar NFS-e Guarulhos: #{e.message}"
    end

    private

    def pkcs12
      @pkcs12 ||= @establishment.certificate_pkcs12
    end

    def wsdl_url
      WSDL_URLS.fetch(@establishment.ambiente)
    end

    def soap_client
      @soap_client ||= Savon.client(
        wsdl: wsdl_url,
        ssl_client_cert: pkcs12.certificate,
        ssl_client_key: pkcs12.key,
        ssl_verify_mode: :peer,
        log: !Rails.env.production?,
        raise_errors: false,
        convert_request_keys_to: :none
      )
    end

    def call_soap(operation, body)
      response = soap_client.call(operation, message: body)
      raise Error, "SOAP fault do webservice de Guarulhos: #{response.http.body}" unless response.success?

      response
    end

    # Monta o XML do Rps no formato ABRASF 2.04. A tag <Signature> fica
    # ANINHADA dentro do elemento com o Id referenciado (InfDeclaracaoPrestacaoServico),
    # não como irmã dele — só assim o transform "enveloped-signature" do
    # XMLDSig consegue achar e remover a própria assinatura antes de calcular
    # o hash (senão vira referência circular). Confirmado com um spike real
    # (certificado autoassinado, gem xmldsig 0.7.0) antes de escrever isto.
    def build_rps_xml(invoice)
      estab = @establishment
      endereco = invoice.tomador_endereco || {}
      rps_id = "rps#{invoice.serie_rps}#{invoice.numero_rps}"

      Nokogiri::XML::Builder.new do |xml|
        xml.Rps(xmlns: NAMESPACE) do
          xml.InfDeclaracaoPrestacaoServico(Id: rps_id) do
            xml.Rps do
              xml.IdentificacaoRps do
                xml.Numero invoice.numero_rps
                xml.Serie invoice.serie_rps
                xml.Tipo '1'
              end
              xml.DataEmissao invoice.created_at.strftime('%Y-%m-%d')
              xml.Status '1'
            end
            xml.Competencia invoice.created_at.strftime('%Y-%m-%d')
            xml.Servico do
              xml.Valores do
                xml.ValorServicos format('%.2f', invoice.valor_servicos)
                xml.ValorDeducoes format('%.2f', invoice.valor_deducoes)
                xml.ValorIss format('%.2f', invoice.valor_iss)
                xml.Aliquota format('%.4f', invoice.aliquota_iss_pct.to_f / 100)
              end
              xml.IssRetido '2'
              xml.ItemListaServico invoice.codigo_servico_municipal
              xml.Discriminacao invoice.discriminacao
              xml.CodigoMunicipio estab.municipio_ibge_code
            end
            xml.Prestador do
              xml.CpfCnpj do
                xml.Cnpj org_cnpj_digits
              end
              xml.InscricaoMunicipal estab.inscricao_municipal
            end
            xml.Tomador do
              xml.IdentificacaoTomador do
                xml.CpfCnpj do
                  cpf_cnpj_node(xml, invoice.tomador_cpf_cnpj)
                end
              end
              xml.RazaoSocial invoice.tomador_nome
              if endereco.present?
                xml.Endereco do
                  xml.Endereco endereco['logradouro']
                  xml.Numero endereco['numero']
                  xml.Bairro endereco['bairro']
                  xml.CodigoMunicipio endereco['codigo_municipio']
                  xml.Uf endereco['uf']
                  xml.Cep endereco['cep']
                end
              end
              xml.Contato do
                xml.Email invoice.tomador_email if invoice.tomador_email.present?
              end
            end
            xml.Signature(xmlns: 'http://www.w3.org/2000/09/xmldsig#') do
              xml.SignedInfo do
                xml.CanonicalizationMethod(Algorithm: 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315')
                xml.SignatureMethod(Algorithm: 'http://www.w3.org/2000/09/xmldsig#rsa-sha1')
                xml.Reference(URI: "##{rps_id}") do
                  xml.Transforms do
                    xml.Transform(Algorithm: 'http://www.w3.org/2000/09/xmldsig#enveloped-signature')
                  end
                  xml.DigestMethod(Algorithm: 'http://www.w3.org/2000/09/xmldsig#sha1')
                  xml.DigestValue
                end
              end
              xml.SignatureValue
              xml.KeyInfo do
                xml.X509Data do
                  xml.X509Certificate x509_certificate_base64
                end
              end
            end
          end
        end
      end.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML | Nokogiri::XML::Node::SaveOptions::NO_DECLARATION)
    end

    def build_cancelamento_xml(invoice)
      cancel_id = "cancel#{invoice.numero_nfse}"

      Nokogiri::XML::Builder.new do |xml|
        xml.CancelarNfseEnvio(xmlns: NAMESPACE) do
          xml.Pedido do
            xml.InfPedidoCancelamento(Id: cancel_id) do
              xml.IdentificacaoNfse do
                xml.Numero invoice.numero_nfse
                xml.CpfCnpj do
                  xml.Cnpj org_cnpj_digits
                end
                xml.InscricaoMunicipal @establishment.inscricao_municipal
                xml.CodigoMunicipio @establishment.municipio_ibge_code
              end
              xml.CodigoCancelamento '1'
              xml.Signature(xmlns: 'http://www.w3.org/2000/09/xmldsig#') do
                xml.SignedInfo do
                  xml.CanonicalizationMethod(Algorithm: 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315')
                  xml.SignatureMethod(Algorithm: 'http://www.w3.org/2000/09/xmldsig#rsa-sha1')
                  xml.Reference(URI: "##{cancel_id}") do
                    xml.Transforms do
                      xml.Transform(Algorithm: 'http://www.w3.org/2000/09/xmldsig#enveloped-signature')
                    end
                    xml.DigestMethod(Algorithm: 'http://www.w3.org/2000/09/xmldsig#sha1')
                    xml.DigestValue
                  end
                end
                xml.SignatureValue
                xml.KeyInfo do
                  xml.X509Data do
                    xml.X509Certificate x509_certificate_base64
                  end
                end
              end
            end
          end
        end
      end.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML | Nokogiri::XML::Node::SaveOptions::NO_DECLARATION)
    end

    # O certificado já entra preenchido no XML (build_rps_xml/build_cancelamento_xml)
    # ANTES de assinar — reabrir o XML já assinado com Nokogiri pra só then preencher
    # o X509Certificate e serializar de novo com `to_s` parecia inofensivo (o
    # certificado fica fora do que é hasheado, já que o transform
    # enveloped-signature remove a tag <Signature> inteira antes de calcular o
    # digest do nó referenciado), mas na prática QUEBRAVA a assinatura: o
    # reparse+serialize do documento inteiro muda formatação (ex.: tags vazias
    # como <Cnpj/> viram <Cnpj></Cnpj> ou vice-versa) o suficiente pra
    # canonicalização do <SignedInfo>/nó referenciado não bater mais depois —
    # confirmado com um teste real (self-signed cert): assinatura só validava
    # quando o certificado já estava no XML antes de chamar `.sign`.
    def sign(xml_string)
      Xmldsig::SignedDocument.new(xml_string, id_attr: 'Id').sign(pkcs12.key)
    end

    def x509_certificate_base64
      Base64.strict_encode64(pkcs12.certificate.to_der)
    end

    def envelope_body(signed_xml)
      { 'xml' => signed_xml }
    end

    def consulta_situacao_body(invoice)
      {
        'xml' => Nokogiri::XML::Builder.new do |xml|
          xml.ConsultarSituacaoLoteRpsEnvio(xmlns: NAMESPACE) do
            xml.Prestador do
              xml.CpfCnpj { xml.Cnpj org_cnpj_digits }
              xml.InscricaoMunicipal @establishment.inscricao_municipal
            end
            xml.Protocolo invoice.protocolo
          end
        end.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML | Nokogiri::XML::Node::SaveOptions::NO_DECLARATION)
      }
    end

    # Funil único de leitura da resposta ABRASF — municípios ABRASF devolvem
    # rejeição via <ListaMensagemRetorno><MensagemRetorno><Codigo/><Mensagem/>,
    # e é essa mensagem real da prefeitura que precisa cair em
    # erro_mensagem/xml_retorno pra ser útil de debugar depois.
    def apply_emissao_response(invoice, response)
      body = response.http.body
      doc = Nokogiri::XML(body)
      invoice.xml_retorno = body

      mensagem_erro = extract_mensagem_erro(doc)
      if mensagem_erro
        invoice.status = 'error'
        invoice.erro_mensagem = mensagem_erro
      else
        protocolo = doc.at_xpath('//xmlns:Protocolo', 'xmlns' => NAMESPACE)&.content
        invoice.protocolo = protocolo
        invoice.status = 'processing'
      end
      invoice.save!
      invoice
    end

    def apply_situacao_response(invoice, response)
      body = response.http.body
      doc = Nokogiri::XML(body)
      invoice.xml_retorno = body

      mensagem_erro = extract_mensagem_erro(doc)
      numero_nfse = doc.at_xpath('//xmlns:Numero', 'xmlns' => NAMESPACE)&.content
      codigo_verificacao = doc.at_xpath('//xmlns:CodigoVerificacao', 'xmlns' => NAMESPACE)&.content

      if mensagem_erro
        invoice.status = 'error'
        invoice.erro_mensagem = mensagem_erro
      elsif numero_nfse.present?
        invoice.numero_nfse = numero_nfse
        invoice.codigo_verificacao = codigo_verificacao
        invoice.status = 'authorized'
      end
      invoice.save!
      invoice
    end

    def apply_cancelamento_response(invoice, response)
      body = response.http.body
      doc = Nokogiri::XML(body)
      invoice.xml_retorno = body

      mensagem_erro = extract_mensagem_erro(doc)
      if mensagem_erro
        invoice.erro_mensagem = mensagem_erro
      else
        invoice.status = 'cancelled'
      end
      invoice.save!
      invoice
    end

    def extract_mensagem_erro(doc)
      mensagem = doc.at_xpath('//xmlns:MensagemRetorno/xmlns:Mensagem', 'xmlns' => NAMESPACE)&.content
      codigo = doc.at_xpath('//xmlns:MensagemRetorno/xmlns:Codigo', 'xmlns' => NAMESPACE)&.content
      return nil if mensagem.blank?

      codigo.present? ? "[#{codigo}] #{mensagem}" : mensagem
    end

    def cpf_cnpj_node(xml, doc)
      digits = doc.to_s.gsub(/\D/, '')
      digits.length > 11 ? xml.Cnpj(digits) : xml.Cpf(digits)
    end

    def org_cnpj_digits
      GlobalConfigService.load('ORG_CNPJ', '').to_s.gsub(/\D/, '')
    end
  end
end
