# Client de NFS-e para Guarulhos, via GissOnline (padrão eicon/ABRASF 2.04).
#
# Cada operação recebe DOIS parâmetros string no corpo SOAP (`nfseCabecMsg`,
# com o cabeçalho de versão, e `nfseDadosMsg`, com a mensagem em si) e devolve
# um único `outputXML`. Confirmado contra o WSDL real
# (`https://ws-guarulhos.giss.com.br/service-ws/nf/nfse-ws?wsdl`) e o manual
# oficial de integração (NFS-e Manual de Integração V 2.03).
#
# Por isso NÃO usamos Savon: o WSDL é eicon (wrapper genérico `input`/`output`),
# o que faz o Savon gerar um envelope incompatível. Montamos o envelope SOAP na
# mão e usamos Net::HTTP com mTLS (certificado A1) — determinístico e sem
# surpresa de namespace.
#
# Namespaces: os dados usam o namespace Giss
# (`http://www.giss.com.br/<schema>-v2_04.xsd`), NÃO o abrasf.org.br clássico.
# O cabeçalho também tem namespace próprio (`cabecalho-v2_04.xsd`) — com o
# namespace antigo a prefeitura responde `E183` ("cabeçalho fora do padrão")
# antes mesmo de olhar o resto do XML.
#
# Emissão: `GerarNfse` e `RecepcionarLoteRpsSincrono` respondem `A01` mesmo com
# o XML correto, então só o lote ASSÍNCRONO (`RecepcionarLoteRps`) emite. Ele
# devolve um protocolo e a nota é resolvida depois via `ConsultarLoteRps` (o
# `ServiceInvoices::PollStatusJob` faz a consulta). O RPS vira `processing`
# após o protocolo e `authorized`/`error` depois da consulta.
#
# Assinatura XMLDSig (RSA-SHA1, C14N 1.0): cada RPS é assinado individualmente
# (Signature DENTRO de cada `<Rps>`, referenciando o `InfDeclaracaoPrestacaoServico`
# pelo Id) E o lote é assinado no final (Signature na raiz, referenciando o
# `LoteRps` pelo Id). Assinar só o lote devolve `E174`; usar `URI=""` na
# assinatura do lote invalida as assinaturas dos RPS e também dá `E174`.
#
# Autenticação: certificado A1 (mTLS) na conexão + a assinatura acima. O CNPJ do
# prestador é lido do próprio certificado (o subject ICP-Brasil traz
# "RAZAO SOCIAL:CNPJ" no CN), com fallback pro GlobalConfig.
module Guarulhos
  class Client < NotaFiscal::ProviderClient
    class Error < NotaFiscal::ProviderClient::Error; end

    ENDPOINT = 'https://ws-guarulhos.giss.com.br/service-ws/nf/nfse-ws'.freeze
    SOAP_NS = 'http://nfse.abrasf.org.br'.freeze
    DSIG_NS = 'http://www.w3.org/2000/09/xmldsig#'.freeze
    NS_BASE = 'http://www.giss.com.br'.freeze
    DATA_VERSION = '2.04'.freeze

    C14N = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315'.freeze
    RSA_SHA1 = 'http://www.w3.org/2000/09/xmldsig#rsa-sha1'.freeze
    SHA1_NS = 'http://www.w3.org/2000/09/xmldsig#sha1'.freeze
    ENVELOPED = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature'.freeze

    # Código de país do Brasil (tsCodigoPaisIbge, 4 dígitos, tabela ISO/IBGE:
    # 076 -> "0076"). O manual cita "Bacen" e sugere 1058, mas o serviço recusa
    # esse valor com E384; 0076 é o que a implementação de referência envia.
    # Sem o campo a prefeitura responde E383.
    CODIGO_PAIS_BRASIL = '0076'.freeze

    # Prefixo do namespace de tipos (onde vivem tcLoteRps, tcDadosServico, etc.).
    T = 'tipos'.freeze

    def emitir(invoice)
      xml = sign(build_lote_xml(invoice))
      invoice.xml_envio = xml
      invoice.save!
      output = soap_call('RecepcionarLoteRps', xml)
      apply_recepcao_response(invoice, output)
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Falha ao emitir NFS-e Guarulhos: #{e.message}"
    end

    def consultar_situacao(invoice)
      return invoice if invoice.protocolo.blank?

      output = soap_call('ConsultarLoteRps', sign(build_consulta_xml(invoice)))
      apply_situacao_response(invoice, output)
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Falha ao consultar situação NFS-e Guarulhos: #{e.message}"
    end

    def cancelar(invoice)
      output = soap_call('CancelarNfse', sign(build_cancelamento_xml(invoice)))
      apply_cancelamento_response(invoice, output)
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Falha ao cancelar NFS-e Guarulhos: #{e.message}"
    end

    private

    def pkcs12
      @pkcs12 ||= @establishment.certificate_pkcs12
    end

    # O CNPJ do prestador tem que ser o do certificado usado (o manual exige que
    # o certificado de assinatura contenha o CNPJ do emissor). Extraímos do
    # subject (padrão ICP-Brasil: CN = "RAZAO SOCIAL:CNPJ") e só caímos no
    # GlobalConfig se o certificado não trouxer nada.
    def prestador_cnpj
      @prestador_cnpj ||= begin
        subject = pkcs12.certificate.subject.to_s
        subject[/CN=[^\/]*?:(\d{14})/, 1] || subject[/\d{14}/] || org_cnpj_digits
      end
    end

    def org_cnpj_digits
      GlobalConfigService.load('ORG_CNPJ', '').to_s.gsub(/\D/, '')
    end

    # ------------------------------------------------------------------ XML

    def giss_ns(schema)
      "#{NS_BASE}/#{schema}-v#{DATA_VERSION.tr('.', '_')}.xsd"
    end

    def tipos(name)
      "#{T}:#{name}"
    end

    def xml_declaration
      '<?xml version="1.0" encoding="UTF-8"?>'
    end

    def root_element(name, body)
      %(<#{name} xmlns="#{giss_ns(name_to_schema(name))}" xmlns:#{T}="#{giss_ns('tipos')}">#{body}</#{name}>)
    end

    def name_to_schema(name)
      {
        'EnviarLoteRpsEnvio' => 'enviar-lote-rps-envio',
        'ConsultarLoteRpsEnvio' => 'consultar-lote-rps-envio',
        'CancelarNfseEnvio' => 'cancelar-nfse-envio'
      }.fetch(name)
    end

    def elem(name, value, attrs = {})
      return '' if value.nil? || value.to_s.empty?

      "<#{name}#{attrs_xml(attrs)}>#{escape_xml(value)}</#{name}>"
    end

    # Grupo que desaparece quando não tem filho nenhum (para opcionais).
    def grp(name, children, attrs = {})
      body = join_children(children)
      return '' if body.empty?

      "<#{name}#{attrs_xml(attrs)}>#{body}</#{name}>"
    end

    # Grupo obrigatório: mantém o elemento mesmo sem filhos.
    def rgrp(name, children, attrs = {})
      "<#{name}#{attrs_xml(attrs)}>#{join_children(children)}</#{name}>"
    end

    def join_children(children)
      children.compact.reject { |c| c.to_s.empty? }.join
    end

    def attrs_xml(attrs)
      attrs.reject { |_, v| v.nil? || v.to_s.empty? }
           .map { |k, v| %( #{k}="#{escape_xml(v)}") }.join
    end

    def escape_xml(value)
      value.to_s
           .gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
           .gsub('"', '&quot;').gsub("'", '&apos;')
    end

    def amount(value)
      return nil if value.nil? || value.to_s.empty?

      format('%.2f', value.to_f)
    end

    def iso_date(value)
      value.respond_to?(:strftime) ? value.strftime('%Y-%m-%d') : value.to_s[0, 10]
    end

    def truncate(value, limit)
      value.to_s.length > limit ? value.to_s[0, limit] : value.to_s
    end

    def rps_id(invoice)
      "rps#{invoice.serie_rps}#{invoice.numero_rps}"
    end

    def lote_id(invoice)
      "lote#{invoice.numero_rps}"
    end

    def cancel_id(invoice)
      "canc#{invoice.numero_nfse}"
    end

    # ------------------------------------------------------------------ blocos

    def prestador_party(tag, cnpj, inscricao)
      rgrp(tag, [
        rgrp(tipos('CpfCnpj'), [elem(tipos('Cnpj'), cnpj)]),
        elem(tipos('InscricaoMunicipal'), inscricao)
      ])
    end

    # No XML do Giss o ItemListaServico vai com ponto ("10.08", é essa a
    # enumeração do schema); a chave da tabela de atividades é só dígitos.
    def item_lista_servico(invoice)
      invoice.codigo_servico_municipal.to_s.gsub(/\D/, '')
    end

    # Código de tributação municipal (tsCodigoTributacao, até 20 caracteres).
    # A prefeitura não usa o item da LC 116: cada item mapeia para um código da
    # tabela de atividades do município, obtido na rota pública
    # `/service-atividade/api/atividade/v2/lista-atividades/3518800`.
    # Não dá para derivar do item (um item tem várias atividades), então esta
    # tabela guarda a atividade padrão de cada item usado pela empresa.
    # 1706 trocado de 731900201 ("Promoção de vendas/publicidade") pra
    # 731900300 em 28/10/2026 — pedido do usuário, bate exatamente com a
    # atividade econômica PRINCIPAL registrada no CNPJ da empresa (73.19-
    # 0-03 "Marketing direto", ver Cartão CNPJ) para notas de tráfego
    # pago/marketing digital. Não consegui confirmar contra a lista ao
    # vivo da prefeitura (endpoint `/service-atividade/.../lista-
    # atividades/3518800` do comentário acima respondeu 404 em todas as
    # variações de host testadas — path desatualizado ou atrás de algo
    # que não é HTTP simples) — confirmar com o contador na primeira
    # emissão real com este código.
    CODIGOS_TRIBUTACAO_MUNICIPIO = {
      '1008' => '731220001', # Agenciamento de espaços publicitários
      '1009' => '731140002', # Representação de veículos de comunicação
      '1701' => '731900400', # Consultoria em publicidade
      '1706' => '731900300'  # Marketing direto / tráfego pago (CNAE principal da empresa)
    }.freeze

    def codigo_tributacao_municipio(invoice)
      override = invoice.codigo_tributacao_municipio if invoice.respond_to?(:codigo_tributacao_municipio)
      override.presence || CODIGOS_TRIBUTACAO_MUNICIPIO[item_lista_servico(invoice)]
    end

    # Bloco <IBSCBS> (Reforma Tributária, LC 214/2025) — confirmado pelo
    # exemplo de XML completo do manual técnico oficial (v1.0, 14/10/2026,
    # seção 5): fica DENTRO de <Servico><Valores>, depois de <trib>. É só
    # classificação (finalidade/indicadores/CST/cClassTrib/base de cálculo)
    # — o valor do IBS/CBS em si (<IBSCBSTotal>, vIBSUF/vIBSMun/vCBS) é
    # TOTALIZADOR DEVOLVIDO PELA PREFEITURA no retorno, não algo que o
    # emissor calcula e envia. Em 2026 esses valores ainda não entram no
    # total da nota (fase de testes/homologação) — só a classificação já
    # deixa a nota pronta pro schema atual.
    #
    # Valores default cobrem a operação comum desta empresa (venda de
    # serviço B2B nacional, sem comércio exterior — por isso <comExt> fica
    # de fora): finNFSe=0 (regular), indFinal=0 (não é consumo pessoal),
    # cIndOp=000001 e CST=001/cClassTrib=010101 (tributação integral,
    # mesmos valores do exemplo oficial do manual).
    IBS_CBS_CST_PADRAO = '001'
    IBS_CBS_CLASSIFICACAO_PADRAO = '010101'

    # Desabilitado em 29/10/2026: três emissões reais seguidas (RPS 2-4)
    # foram rejeitadas com [E160] Arquivo em desacordo com o XML Schema
    # assim que esse bloco entrou no corpo do lote — mesmo depois de já
    # terem sido descartados como causa o CodigoNbs (RPS 2-3) e o formato
    # do ItemListaServico (RPS 3-4, faltava o ponto: "17.06", não "1706").
    # Isolando as duas únicas mudanças nunca testadas contra o envio real
    # (CodigoNbs e este bloco IBS/CBS), o IBSCBS é o único candidato que
    # sobrou sem teste: o XML declara schema v2_04
    # (enviar-lote-rps-envio-v2_04.xsd — ver cabeçalho do arquivo), que
    # antecede a Reforma Tributária (LC 214/2025); o manual técnico que
    # descreve esse bloco pode se referir a uma versão de schema que
    # Guarulhos/GissOnline ainda não publicou para esse endpoint. Mantido
    # aqui, só não chamado, até confirmar com a prefeitura/contador se e
    # quando reativar.
    def ibs_cbs_node(invoice)
      rgrp(tipos('IBSCBS'), [
        elem(tipos('finNFSe'), '0'),
        elem(tipos('indFinal'), '0'),
        elem(tipos('cIndOp'), '000001'),
        elem(tipos('indDest'), '0'),
        rgrp(tipos('gIBSCBS'), [
          elem(tipos('CST'), IBS_CBS_CST_PADRAO),
          elem(tipos('cClassTrib'), IBS_CBS_CLASSIFICACAO_PADRAO),
          elem(tipos('cLocalidadeIncid'), @establishment.municipio_ibge_code),
          elem(tipos('pRedutor'), '0.0000'),
          # Base de cálculo "antes das reduções" — aproximação a partir do
          # que o ServiceInvoice já tem (valor do serviço menos o ISS já
          # destacado); não há bloco de PIS/COFINS detalhado nesta 1ª
          # versão pra abater também, isso é só informativo em 2026.
          elem(tipos('vBC'), amount(invoice.valor_servicos.to_f - invoice.valor_iss.to_f))
        ])
      ])
    end

    def cpf_cnpj_elem(value)
      digits = value.to_s.gsub(/\D/, '')
      digits.length > 11 ? elem(tipos('Cnpj'), digits) : elem(tipos('Cpf'), digits)
    end

    def servico_node(invoice)
      rgrp(tipos('Servico'), [
        rgrp(tipos('Valores'), [
          elem(tipos('ValorServicos'), amount(invoice.valor_servicos)),
          elem(tipos('ValorDeducoes'), amount(invoice.valor_deducoes)),
          elem(tipos('ValorIss'), amount(invoice.valor_iss)),
          # A alíquota vai como FRAÇÃO: 2% => 0.0200. Mandar o percentual cru
          # (2.0) significa 200% e a prefeitura recusa com E165.
          elem(tipos('Aliquota'), format('%.4f', invoice.aliquota_iss_pct.to_f / 100)),
          # Carga tributária aproximada (Lei 12.741/2012). O município exige os
          # percentuais ou o indicador de não destaque (Decreto 8.264/2014);
          # indTotTrib=0 é o único valor aceito para "não informar".
          rgrp(tipos('trib'), [
            rgrp(tipos('totTrib'), [elem(tipos('indTotTrib'), '0')])
          ])
          # ibs_cbs_node(invoice) desabilitado — ver comentário na definição do método acima.
        ]),
        elem(tipos('IssRetido'), '2'),
        elem(tipos('ItemListaServico'), invoice.codigo_servico_municipal),
        # Guarulhos exige o código de tributação municipal (E202 sem ele e E35
        # se o código não existir na tabela do município); o manual marca 0-1,
        # mas a prefeitura recusa o lote sem o campo.
        elem(tipos('CodigoTributacaoMunicipio'), codigo_tributacao_municipio(invoice)),
        # Código NBS (Nomenclatura Brasileira de Serviços) — o manual técnico
        # oficial (v1.0, 14/10/2026, pós Reforma Tributária LC 214/2025) marca
        # esse campo Ocorr. "1-1" (obrigatório) logo após CodigoTributacaoMunicipio
        # e antes de Discriminacao. A nota 279 (19/10/2026) foi aceita sem ele,
        # então a prefeitura ainda não está rejeitando por omissão — mas como
        # CodigoTributacaoMunicipio também é "0-1" no manual e na prática já dá
        # E202 sem ele (ver comentário acima), é prudente tratar NBS do mesmo
        # jeito antes que vire rejeição de verdade.
        elem(tipos('CodigoNbs'), invoice.codigo_nbs),
        elem(tipos('Discriminacao'), truncate(invoice.discriminacao, 2000)),
        elem(tipos('CodigoMunicipio'), @establishment.municipio_ibge_code),
        elem(tipos('CodigoPais'), CODIGO_PAIS_BRASIL),
        elem(tipos('ExigibilidadeISS'), '1'),
        elem(tipos('MunicipioIncidencia'), @establishment.municipio_ibge_code)
      ])
    end

    def tomador_node(invoice)
      rgrp(tipos('TomadorServico'), [
        rgrp(tipos('IdentificacaoTomador'), [
          rgrp(tipos('CpfCnpj'), [cpf_cnpj_elem(invoice.tomador_cpf_cnpj)])
        ]),
        elem(tipos('RazaoSocial'), truncate(invoice.tomador_nome, 150)),
        endereco_node(invoice.tomador_endereco || {}),
        contato_node(invoice)
      ])
    end

    def endereco_node(endereco)
      grp(tipos('Endereco'), [
        elem(tipos('Endereco'), truncate(endereco['logradouro'], 125)),
        elem(tipos('Numero'), endereco['numero']),
        elem(tipos('Bairro'), endereco['bairro']),
        elem(tipos('CodigoMunicipio'), endereco['codigo_municipio']),
        elem(tipos('Uf'), endereco['uf']),
        elem(tipos('Cep'), endereco['cep'])
      ])
    end

    def contato_node(invoice)
      return '' if invoice.tomador_email.blank?

      rgrp(tipos('Contato'), [elem(tipos('Email'), invoice.tomador_email)])
    end

    def rps_node(invoice)
      id = rps_id(invoice)
      inf = rgrp(tipos('InfDeclaracaoPrestacaoServico'), [
        rgrp(tipos('Rps'), [
          rgrp(tipos('IdentificacaoRps'), [
            elem(tipos('Numero'), invoice.numero_rps),
            elem(tipos('Serie'), invoice.serie_rps),
            elem(tipos('Tipo'), '1')
          ]),
          elem(tipos('DataEmissao'), iso_date(invoice.created_at)),
          elem(tipos('Status'), '1')
        ], Id: "#{id}i"),
        elem(tipos('Competencia'), iso_date(invoice.created_at)),
        servico_node(invoice),
        prestador_party(tipos('Prestador'), prestador_cnpj, @establishment.inscricao_municipal),
        tomador_node(invoice),
        elem(tipos('OptanteSimplesNacional'), '2'),
        elem(tipos('IncentivoFiscal'), '2')
      ], Id: id)

      # A Signature fica IRMÃ do InfDeclaracao (dentro do Rps), referenciando o
      # Id do InfDeclaracao. É onde o schema a espera.
      rgrp(tipos('Rps'), [inf, signature_placeholder(id)])
    end

    def build_lote_xml(invoice)
      lote = rgrp('LoteRps', [
        elem(tipos('NumeroLote'), invoice.numero_rps),
        prestador_party(tipos('Prestador'), prestador_cnpj, @establishment.inscricao_municipal),
        elem(tipos('QuantidadeRps'), '1'),
        rgrp(tipos('ListaRps'), [rps_node(invoice)])
      ], Id: lote_id(invoice), versao: DATA_VERSION)

      xml_declaration + root_element('EnviarLoteRpsEnvio', lote + signature_placeholder(lote_id(invoice)))
    end

    def build_consulta_xml(invoice)
      body = prestador_party('Prestador', prestador_cnpj, @establishment.inscricao_municipal) +
             elem('Protocolo', invoice.protocolo) +
             signature_placeholder('')

      xml_declaration + root_element('ConsultarLoteRpsEnvio', body)
    end

    def build_cancelamento_xml(invoice)
      id = cancel_id(invoice)
      pedido = rgrp('Pedido', [
        rgrp(tipos('InfPedidoCancelamento'), [
          rgrp(tipos('IdentificacaoNfse'), [
            elem(tipos('Numero'), invoice.numero_nfse),
            rgrp(tipos('CpfCnpj'), [elem(tipos('Cnpj'), prestador_cnpj)]),
            elem(tipos('InscricaoMunicipal'), @establishment.inscricao_municipal),
            elem(tipos('CodigoMunicipio'), @establishment.municipio_ibge_code)
          ]),
          elem(tipos('CodigoCancelamento'), '1')
        ], Id: id),
        signature_placeholder(id)
      ])

      xml_declaration + root_element('CancelarNfseEnvio', pedido)
    end

    # Template de assinatura XMLDSig com os valores vazios — preenchidos por
    # `sign` depois de parsear. `uri` vazia assina o documento inteiro (digest do
    # elemento raiz); com Id, referencia o nó `[@Id]`.
    def signature_placeholder(id)
      uri = id.to_s.empty? ? '' : "##{id}"
      '<Signature xmlns="' + DSIG_NS + '">' \
        '<SignedInfo>' \
          "<CanonicalizationMethod Algorithm=\"#{C14N}\"/>" \
          "<SignatureMethod Algorithm=\"#{RSA_SHA1}\"/>" \
          "<Reference URI=\"#{uri}\">" \
            '<Transforms>' \
              "<Transform Algorithm=\"#{ENVELOPED}\"/>" \
              "<Transform Algorithm=\"#{C14N}\"/>" \
            '</Transforms>' \
            "<DigestMethod Algorithm=\"#{SHA1_NS}\"/>" \
            '<DigestValue></DigestValue>' \
          '</Reference>' \
        '</SignedInfo>' \
        '<SignatureValue></SignatureValue>' \
        '<KeyInfo>' \
          "<X509Data><X509Certificate>#{x509_certificate_base64}</X509Certificate></X509Data>" \
        '</KeyInfo>' \
      '</Signature>'
    end

    # Assinatura XMLDSig (RSA-SHA1) feita à mão. A gem xmldsig 0.7.0 exige que a
    # <Signature> seja DESCENDENTE do nó referenciado pra aplicar o transform
    # enveloped-signature, mas o schema ABRASF coloca a Signature como IRMÃ do
    # nó assinado (InfDeclaracaoPrestacaoServico / LoteRps). Assinamos então
    # todas as Signatures do documento: o digest cobre o nó referenciado
    # (removendo a própria Signature quando ela está dentro dele, caso do
    # `URI=""`), e o SignatureValue é o RSA-SHA1 sobre o SignedInfo
    # canonicalizado.
    def sign(xml_string)
      doc = Nokogiri::XML(xml_string)
      doc.xpath("//*[local-name()='Signature']").each { |signature| sign_one(doc, signature) }
      doc.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    def sign_one(doc, signature)
      signed_info = signature.at_xpath("./*[local-name()='SignedInfo']")
      reference = signed_info.at_xpath("./*[local-name()='Reference']")
      id = reference.attribute('URI').to_s.sub(/\A#/, '')

      digest =
        if id.empty?
          # Assinatura do documento inteiro: o enveloped-signature tira a própria
          # Signature do digest. Ela é o último filho do root, então removê-la e
          # reanexá-la preserva a ordem.
          referenced = doc.root
          parent = signature.parent
          signature.unlink
          value = OpenSSL::Digest::SHA1.digest(referenced.canonicalize)
          parent.add_child(signature)
          value
        else
          referenced = doc.at_xpath("//*[@Id='#{id}']")
          raise Error, "nó referenciado ##{id} não encontrado no XML" if referenced.nil?

          OpenSSL::Digest::SHA1.digest(referenced.canonicalize)
        end

      reference.at_xpath("./*[local-name()='DigestValue']").content = Base64.strict_encode64(digest)
      signature_value = pkcs12.key.sign(OpenSSL::Digest.new('SHA1'), signed_info.canonicalize)
      signature.at_xpath("./*[local-name()='SignatureValue']").content = Base64.strict_encode64(signature_value)
    end

    def x509_certificate_base64
      Base64.strict_encode64(pkcs12.certificate.to_der)
    end

    # ------------------------------------------------------------------- SOAP

    # Envelope SOAP 1.1 do padrão eicon: wrapper `<Operacao>Request` no namespace
    # do serviço, com os dois parâmetros string (cabeçalho + dados) escapados e
    # SEM namespace (o schema eicon os declara unqualified).
    def soap_call(operation, dados_xml)
      response = http_post(soap_envelope(operation, dados_xml), operation)
      parse_soap_response(response)
    end

    def soap_envelope(operation, dados_xml)
      xml_declaration +
        %(<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ws="#{SOAP_NS}">) +
        '<soapenv:Header/><soapenv:Body>' +
        "<ws:#{operation}Request>" \
        "<nfseCabecMsg>#{escape_xml(cabecalho_xml)}</nfseCabecMsg>" \
        "<nfseDadosMsg>#{escape_xml(dados_xml)}</nfseDadosMsg>" \
        "</ws:#{operation}Request>" \
        '</soapenv:Body></soapenv:Envelope>'
    end

    def cabecalho_xml
      %(<cabecalho xmlns="#{giss_ns('cabecalho')}" versao="#{DATA_VERSION}"><versaoDados>#{DATA_VERSION}</versaoDados></cabecalho>)
    end

    def http_post(body, operation)
      uri = URI.parse(ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.cert = pkcs12.certificate
      http.key = pkcs12.key
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 30
      http.read_timeout = 90

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'text/xml;charset=UTF-8'
      request['SOAPAction'] = %("#{SOAP_NS}/#{operation}")
      request.body = body
      http.request(request)
    end

    # Extrai o `outputXML` (a resposta de negócio de verdade) do envelope SOAP.
    # O conteúdo vem escapado como texto dentro de <outputXML>, então precisa
    # ser lido via .text e só então parseado como XML.
    def parse_soap_response(response)
      doc = Nokogiri::XML(response.body)
      fault = doc.at_xpath("//*[local-name()='Fault']")
      if fault
        raise Error, "SOAP fault Guarulhos: #{fault.at_xpath(".//*[local-name()='faultstring']")&.text || response.body}"
      end

      output = doc.at_xpath("//*[local-name()='outputXML']")&.text
      raise Error, "Resposta sem outputXML (HTTP #{response.code}): #{response.body.to_s[0, 500]}" if output.blank?

      output
    end

    # -------------------------------------------------------------- respostas

    # RecepcionarLoteRps: guarda o protocolo e deixa o RPS `processing`. A nota
    # em si só aparece na ConsultarLoteRps (feita pelo PollStatusJob).
    def apply_recepcao_response(invoice, output_xml)
      doc = Nokogiri::XML(output_xml)
      invoice.xml_retorno = output_xml

      if (mensagem = extract_mensagem_erro(doc))
        invoice.status = 'error'
        invoice.erro_mensagem = mensagem
      else
        protocolo = doc.at_xpath("//*[local-name()='Protocolo']")&.text
        if protocolo.present?
          invoice.protocolo = protocolo
          invoice.status = 'processing'
          invoice.erro_mensagem = nil
        else
          invoice.status = 'error'
          invoice.erro_mensagem = 'Resposta da prefeitura sem protocolo e sem mensagem de erro'
        end
      end
      invoice.save!
      invoice
    end

    def apply_situacao_response(invoice, output_xml)
      doc = Nokogiri::XML(output_xml)
      invoice.xml_retorno = output_xml
      situacao = doc.at_xpath("//*[local-name()='Situacao']")&.text

      case situacao
      when '4'
        inf = doc.at_xpath("//*[local-name()='InfNfse']")
        numero = inf&.at_xpath("./*[local-name()='Numero']")&.text
        codigo = inf&.at_xpath("./*[local-name()='CodigoVerificacao']")&.text
        if numero.present?
          invoice.numero_nfse = numero
          invoice.codigo_verificacao = codigo
          invoice.status = 'authorized'
          invoice.erro_mensagem = nil
        else
          invoice.status = 'error'
          invoice.erro_mensagem = extract_mensagem_erro(doc) || 'Lote processado sem NFS-e na resposta'
        end
      when '3'
        invoice.status = 'error'
        invoice.erro_mensagem = extract_mensagem_erro(doc) || 'Lote processado com erro pela prefeitura'
      when '1', '2'
        # Não recebido / não processado: a resposta traz só um aviso
        # ("Remessa ainda não foi processada"), não é erro. Segue processando.
        invoice.status = 'processing'
        invoice.erro_mensagem = nil
      else
        if (mensagem = extract_mensagem_erro(doc))
          invoice.status = 'error'
          invoice.erro_mensagem = mensagem
        end
      end
      invoice.save!
      invoice
    end

    def apply_cancelamento_response(invoice, output_xml)
      doc = Nokogiri::XML(output_xml)
      invoice.xml_retorno = output_xml

      if (mensagem = extract_mensagem_erro(doc))
        invoice.erro_mensagem = mensagem
      else
        invoice.status = 'cancelled'
      end
      invoice.save!
      invoice
    end

    def extract_mensagem_erro(doc)
      node = doc.at_xpath("//*[local-name()='MensagemRetorno' or local-name()='MensagemRetornoLote']")
      return nil if node.nil?

      codigo = node.at_xpath("./*[local-name()='Codigo']")&.text
      mensagem = node.at_xpath("./*[local-name()='Mensagem']")&.text
      correcao = node.at_xpath("./*[local-name()='Correcao']")&.text
      return nil if mensagem.blank? && codigo.blank?

      [codigo.present? ? "[#{codigo}]" : nil, mensagem, correcao].compact.reject(&:blank?).join(' ')
    end
  end
end
