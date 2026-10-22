# Client de NF-e 55 / NFC-e 65 direto na SEFAZ-SP — SEM contratar nenhum
# provedor terceiro (eNotas/Focus NFe/PlugNotas), pedido explícito do
# usuário. Mesma filosofia do Guarulhos::Client (webservice público do
# governo + certificado A1 já existente), mas layout NACIONAL (NFe 4.00,
# NT2016.002) em vez de municipal — por isso não compartilha nenhum código
# com Guarulhos::Client nem com NotaFiscal::ProviderClient (sistemas
# deliberadamente independentes).
#
# Schema reconstruído a partir do XSD oficial redistribuído pelo projeto
# open-source nfephp-org/sped-nfe (schemes/PL_009_V4/leiauteNFe_v4.00.xsd)
# — é o layout nacional publicado pelo Portal NF-e, não algo específico
# desse projeto. URLs de homologação/produção confirmadas em
# portal.fazenda.sp.gov.br/servicos/nfce/Paginas/WebServices.aspx.
#
# ESCOPO DESTA 1ª VERSÃO (deliberadamente restrito, pra não arriscar um
# schema errado numa operação que este CRM não usa):
#   - Venda de mercadoria nacional simples (sem comércio exterior, sem
#     IPI/II, sem ICMS-ST, sem substituição tributária, sem contingência).
#   - ICMS só via Simples Nacional (ICMSSN102 — CSOSN 102/103/300/400) +
#     PIS/COFINS como "NT" (CST 07 — isento), o default correto pra quem
#     recolhe pelo Simples (PIS/COFINS já estão dentro do DAS unificado).
#   - tpEmis=1 (normal, sem contingência).
# Pedido de tipo de operação fora disso (exportação, ICMS normal/ST,
# indústria com IPI) precisa de extensão antes de usar.
#
# NÃO TESTADO contra homologação de verdade — a máquina de desenvolvimento
# não conseguiu completar o handshake TLS com homologacao.nfce.fazenda.
# sp.gov.br (cadeia de certificados ICP-Brasil incompleta no trust store
# local). Validar na primeira tentativa real antes de confiar no 100%.
module GoodsInvoices
  module SefazSp
    class Client < GoodsInvoices::ProviderClient
      class Error < GoodsInvoices::ProviderClient::Error; end

      ENDPOINTS = {
        'homologacao' => 'https://homologacao.nfce.fazenda.sp.gov.br/ws/NFeAutorizacao4.asmx',
        'producao' => 'https://nfce.fazenda.sp.gov.br/ws/NFeAutorizacao4.asmx'
      }.freeze
      CONSULTA_ENDPOINTS = {
        'homologacao' => 'https://homologacao.nfce.fazenda.sp.gov.br/ws/NFeConsultaProtocolo4.asmx',
        'producao' => 'https://nfce.fazenda.sp.gov.br/ws/NFeConsultaProtocolo4.asmx'
      }.freeze

      NFE_NS = 'http://www.portalfiscal.inf.br/nfe'.freeze
      SOAP_NS = 'http://www.w3.org/2003/05/soap-envelope'.freeze
      WSDL_NS = 'http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4'.freeze
      DSIG_NS = 'http://www.w3.org/2000/09/xmldsig#'.freeze
      C14N = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315'.freeze
      ENVELOPED = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature'.freeze
      # NFe 4.00 (NT2016.002) exige SHA-256 — não SHA-1 como o ABRASF antigo
      # (Guarulhos). Confundir os dois é o erro mais comum nesse tipo de
      # integração.
      SHA256_NS = 'http://www.w3.org/2001/04/xmlenc#sha256'.freeze
      RSA_SHA256 = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256'.freeze

      def initialize(fiscal_profile)
        super
        @profile = fiscal_profile
      end

      def emitir(invoice)
        chave = gerar_chave(invoice)
        invoice.update!(chave_acesso: chave)

        xml = sign(build_nfe_xml(invoice, chave))
        envio = build_envi_nfe(xml, invoice)
        invoice.update!(xml_envio: envio)

        output = soap_call(envio)
        apply_resposta(invoice, output)
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "Falha ao emitir NF-e/NFC-e na SEFAZ-SP: #{e.message}"
      end

      def consultar_situacao(invoice)
        raise Error, 'Consulta de protocolo ainda não implementada — ver NFeConsultaProtocolo4'
      end

      def cancelar(invoice)
        raise Error, 'Cancelamento ainda não implementado — ver NFeRecepcaoEvento4 (evento 110111)'
      end

      private

      # ---------------------------------------------------------- chave/XML

      def gerar_chave(invoice)
        ChaveAcesso.gerar(
          uf: @profile.uf,
          data_emissao: Time.current,
          cnpj: @profile.cnpj,
          modelo: invoice.modelo,
          serie: invoice.serie,
          numero: invoice.numero
        )
      end

      def elem(name, value, attrs = {})
        return '' if value.nil? || value.to_s.empty?

        "<#{name}#{attrs_xml(attrs)}>#{escape_xml(value)}</#{name}>"
      end

      def grp(name, children, attrs = {})
        body = children.join
        "<#{name}#{attrs_xml(attrs)}>#{body}</#{name}>"
      end

      def attrs_xml(attrs)
        attrs.compact.map { |k, v| " #{k}=\"#{escape_xml(v)}\"" }.join
      end

      def escape_xml(value)
        value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      def amount(value, casas = 2)
        format("%.#{casas}f", value.to_f)
      end

      def ambiente_codigo
        @profile.ambiente == 'producao' ? '1' : '2'
      end

      def build_nfe_xml(invoice, chave)
        inf_nfe_id = "NFe#{chave}"
        corpo = ide_node(invoice, chave) + emit_node + dest_node(invoice) +
                det_nodes(invoice) + total_node(invoice) + transp_node + pag_node(invoice)

        inf_nfe = grp('infNFe', [corpo], Id: inf_nfe_id, versao: '4.00')
        signature = signature_placeholder(inf_nfe_id)

        %(<?xml version="1.0" encoding="UTF-8"?>) +
          %(<NFe xmlns="#{NFE_NS}">#{inf_nfe}#{signature}</NFe>)
      end

      def ide_node(invoice, chave)
        agora = Time.current
        grp('ide', [
          elem('cUF', ChaveAcesso::CODIGO_UF.fetch(@profile.uf.upcase)),
          elem('cNF', chave[35, 8]),
          elem('natOp', invoice.natureza_operacao),
          elem('mod', invoice.modelo),
          elem('serie', invoice.serie),
          elem('nNF', invoice.numero),
          elem('dhEmi', agora.iso8601),
          elem('tpNF', '1'), # saída
          elem('idDest', '1'), # operação interna (dest. mesmo UF) — único caso coberto nesta 1ª versão
          elem('cMunFG', @profile.codigo_municipio),
          elem('tpImp', invoice.nfce? ? '4' : '1'),
          elem('tpEmis', '1'), # normal, sem contingência
          elem('cDV', chave[-1]),
          elem('tpAmb', ambiente_codigo),
          elem('finNFe', '1'), # normal
          elem('indFinal', '1'), # consumidor final
          elem('indPres', invoice.nfce? ? '1' : '2'), # NFC-e=presencial | NF-e=não presencial (e-commerce)
          elem('procEmi', '0'),
          elem('verProc', 'AnuncioCertoCRM 1.0')
        ])
      end

      def emit_node
        grp('emit', [
          elem('CNPJ', @profile.cnpj.gsub(/\D/, '')),
          elem('xNome', @profile.razao_social),
          elem('xFant', @profile.nome_fantasia),
          ender_emit_node,
          elem('IE', @profile.inscricao_estadual.gsub(/\D/, '')),
          elem('CRT', @profile.crt)
        ])
      end

      def ender_emit_node
        grp('enderEmit', [
          elem('xLgr', @profile.logradouro),
          elem('nro', @profile.numero_endereco),
          elem('xCpl', @profile.complemento),
          elem('xBairro', @profile.bairro),
          elem('cMun', @profile.codigo_municipio),
          elem('xMun', @profile.nome_municipio),
          elem('UF', @profile.uf),
          elem('CEP', @profile.cep.to_s.gsub(/\D/, '')),
          elem('fone', @profile.telefone.to_s.gsub(/\D/, ''))
        ])
      end

      # Destinatário é opcional em NFC-e (consumidor não identificado,
      # comum em balcão/delivery) — só monta o bloco quando tem CPF/CNPJ.
      def dest_node(invoice)
        return '' if invoice.destinatario_cpf_cnpj.blank?

        digits = invoice.destinatario_cpf_cnpj.gsub(/\D/, '')
        doc_elem = digits.length > 11 ? elem('CNPJ', digits) : elem('CPF', digits)

        grp('dest', [
          doc_elem,
          elem('xNome', invoice.destinatario_nome),
          elem('indIEDest', '9') # não contribuinte — único caso coberto nesta 1ª versão
        ])
      end

      def det_nodes(invoice)
        invoice.itens.each_with_index.map { |item, index| det_node(item, index + 1) }.join
      end

      def det_node(item, numero_item)
        grp('det', [
          prod_node(item),
          imposto_node(item)
        ], nItem: numero_item)
      end

      def prod_node(item)
        grp('prod', [
          elem('cProd', item['product_id'] || 'SEM-COD'),
          elem('cEAN', 'SEM GTIN'),
          elem('xProd', item['descricao']),
          elem('NCM', item['ncm'].to_s.gsub(/\D/, '')),
          elem('CFOP', item['cfop']),
          elem('uCom', 'UN'),
          elem('qCom', amount(item['quantidade'], 4)),
          elem('vUnCom', amount(item['valor_unitario'], 10)),
          elem('vProd', amount(item['valor_total'])),
          elem('cEANTrib', 'SEM GTIN'),
          elem('uTrib', 'UN'),
          elem('qTrib', amount(item['quantidade'], 4)),
          elem('vUnTrib', amount(item['valor_unitario'], 10)),
          elem('indTot', '1')
        ])
      end

      # ICMSSN102 (CSOSN 102/103/300/400) cobre a operação comum do Simples
      # Nacional sem crédito — mesma simplificação documentada no topo do
      # arquivo. PIS/COFINS como "NT" (CST 07, isento) porque já estão no
      # DAS unificado do Simples.
      def imposto_node(item)
        csosn = %w[102 103 300 400].include?(item['cst_csosn']) ? item['cst_csosn'] : '102'

        grp('imposto', [
          grp('ICMS', [
            grp('ICMSSN102', [
              elem('orig', item['origem'].presence || '0'),
              elem('CSOSN', csosn)
            ])
          ]),
          grp('PIS', [grp('PISNT', [elem('CST', '07')])]),
          grp('COFINS', [grp('COFINSNT', [elem('CST', '07')])])
        ])
      end

      def total_node(invoice)
        valor_produtos = amount(invoice.valor_produtos)
        grp('total', [
          grp('ICMSTot', [
            elem('vBC', amount(0)),
            elem('vICMS', amount(0)),
            elem('vICMSDeson', amount(0)),
            elem('vFCP', amount(0)),
            elem('vBCST', amount(0)),
            elem('vST', amount(0)),
            elem('vFCPST', amount(0)),
            elem('vFCPSTRet', amount(0)),
            elem('vProd', valor_produtos),
            elem('vFrete', amount(invoice.valor_frete)),
            elem('vSeg', amount(0)),
            elem('vDesc', amount(invoice.valor_desconto)),
            elem('vII', amount(0)),
            elem('vIPI', amount(0)),
            elem('vIPIDevol', amount(0)),
            elem('vPIS', amount(0)),
            elem('vCOFINS', amount(0)),
            elem('vOutro', amount(0)),
            elem('vNF', amount(invoice.valor_total))
          ])
        ])
      end

      # Modalidade de frete "9 - sem transporte" — única coberta nesta 1ª
      # versão (venda de balcão/e-commerce sem transportadora própria
      # cadastrada no sistema).
      def transp_node
        grp('transp', [elem('modFrete', '9')])
      end

      def pag_node(invoice)
        grp('pag', [
          grp('detPag', [
            elem('tPag', invoice.forma_pagamento),
            elem('vPag', amount(invoice.valor_total))
          ])
        ])
      end

      # ------------------------------------------------------------ assinatura

      def signature_placeholder(id)
        '<Signature xmlns="' + DSIG_NS + '">' \
          '<SignedInfo>' \
            "<CanonicalizationMethod Algorithm=\"#{C14N}\"/>" \
            "<SignatureMethod Algorithm=\"#{RSA_SHA256}\"/>" \
            "<Reference URI=\"##{id}\">" \
              '<Transforms>' \
                "<Transform Algorithm=\"#{ENVELOPED}\"/>" \
                "<Transform Algorithm=\"#{C14N}\"/>" \
              '</Transforms>' \
              "<DigestMethod Algorithm=\"#{SHA256_NS}\"/>" \
              '<DigestValue></DigestValue>' \
            '</Reference>' \
          '</SignedInfo>' \
          '<SignatureValue></SignatureValue>' \
          '<KeyInfo>' \
            "<X509Data><X509Certificate>#{x509_certificate_base64}</X509Certificate></X509Data>" \
          '</KeyInfo>' \
        '</Signature>'
      end

      def sign(xml_string)
        doc = Nokogiri::XML(xml_string)
        signature = doc.at_xpath("//*[local-name()='Signature']")
        sign_one(doc, signature)
        doc.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end

      def sign_one(doc, signature)
        signed_info = signature.at_xpath("./*[local-name()='SignedInfo']")
        reference = signed_info.at_xpath("./*[local-name()='Reference']")
        id = reference.attribute('URI').to_s.sub(/\A#/, '')

        referenced = doc.at_xpath("//*[@Id='#{id}']")
        raise Error, "nó referenciado ##{id} não encontrado no XML" if referenced.nil?

        digest = OpenSSL::Digest::SHA256.digest(referenced.canonicalize)
        reference.at_xpath("./*[local-name()='DigestValue']").content = Base64.strict_encode64(digest)

        signature_value = pkcs12.key.sign(OpenSSL::Digest.new('SHA256'), signed_info.canonicalize)
        signature.at_xpath("./*[local-name()='SignatureValue']").content = Base64.strict_encode64(signature_value)
      end

      def x509_certificate_base64
        Base64.strict_encode64(pkcs12.certificate.to_der)
      end

      def pkcs12
        @pkcs12 ||= @profile.certificate_pkcs12
      end

      # ------------------------------------------------------------------ SOAP

      def build_envi_nfe(nfe_xml, invoice)
        nfe_sem_declaracao = nfe_xml.sub(/\A<\?xml[^>]*\?>/, '')
        id_lote = Time.current.strftime('%Y%m%d%H%M%S')
        %(<?xml version="1.0" encoding="UTF-8"?>) +
          %(<enviNFe xmlns="#{NFE_NS}" versao="4.00">) +
          %(<idLote>#{id_lote}</idLote><indSinc>1</indSinc>#{nfe_sem_declaracao}</enviNFe>)
      end

      def soap_call(envi_nfe_xml)
        endpoint = ENDPOINTS.fetch(@profile.ambiente)
        uri = URI.parse(endpoint)

        envelope = %(<?xml version="1.0" encoding="UTF-8"?>) +
          %(<soap12:Envelope xmlns:soap12="#{SOAP_NS}">) +
          '<soap12:Body>' \
          "<nfeDadosMsg xmlns=\"#{WSDL_NS}\">#{envi_nfe_xml}</nfeDadosMsg>" \
          '</soap12:Body></soap12:Envelope>'

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.cert = pkcs12.certificate
        http.key = pkcs12.key
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = 30
        http.read_timeout = 60

        request = Net::HTTP::Post.new(uri.request_uri)
        request['Content-Type'] = 'application/soap+xml; charset=utf-8'
        request.body = envelope

        response = http.request(request)
        raise Error, "SEFAZ-SP respondeu HTTP #{response.code}: #{response.body}" unless response.code == '200'

        response.body
      end

      def apply_resposta(invoice, soap_response)
        doc = Nokogiri::XML(soap_response)
        doc.remove_namespaces!

        cstat_lote = doc.at_xpath('//cStat')&.text
        protocolo = doc.at_xpath('//nProt')&.text
        cstat_prot = doc.at_xpath('//protNFe//cStat')&.text || cstat_lote
        motivo = doc.at_xpath('//protNFe//xMotivo')&.text || doc.at_xpath('//xMotivo')&.text

        invoice.xml_retorno = soap_response
        if cstat_prot == '100'
          invoice.status = 'authorized'
          invoice.protocolo = protocolo
          invoice.data_emissao = Time.current
        else
          invoice.status = 'error'
          invoice.erro_mensagem = "SEFAZ-SP: cStat=#{cstat_prot} #{motivo}".strip
        end
        invoice.save!
        invoice
      end
    end
  end
end
