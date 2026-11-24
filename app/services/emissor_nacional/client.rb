# Client do Emissor Nacional (Sefin Nacional NFS-e) — sistema que a partir
# de 01/11/2026 passa a ser obrigatório pra quem é optante do Simples
# Nacional (Resolução CGSN nº 191/2026), no lugar do webservice municipal
# de cada prefeitura (ex.: Guarulhos/GISS). Pesquisado e testado ao vivo em
# 30/10/2026 contra a API real de homologação — GENÉRICO por município
# (lê @establishment.municipio_ibge_code dinamicamente, nada hardcoded
# pra Guarulhos ou qualquer outra cidade específica):
#
#   - Host de homologação: https://sefin.producaorestrita.nfse.gov.br/SefinNacional
#     (achado seguindo o redirect de /SefinNacional -> swagger em
#     /SefinNacional/swagger/docs/v1 — não documentado direto no manual
#     oficial, que só linka o swagger do ADN, um sistema DIFERENTE e
#     SEPARADO: ADN é distribuição/consulta de documentos já emitidos por
#     NSU, não emissão. A API de emissão de verdade é esta, "Sefin
#     Nacional").
#   - Autenticação: mTLS com o MESMO certificado A1 ICP-Brasil já usado
#     hoje pra Guarulhos — testado ao vivo (POST real = HTTP 400 de
#     REGRA DE NEGÓCIO, não de autenticação), sem nenhum credenciamento
#     prévio adicional específico pra API.
#   - Mensagem: JSON {"dpsXmlGZipB64": "<DPS assinada, gzip, base64>"} ->
#     POST /nfse -> 201 com {chaveAcesso, nfseXmlGZipB64 (mesma
#     compressão), alertas[]} ou 400/403/500 com {erros[]}.
#   - Algoritmo de assinatura: NÃO confirmado contra a doc oficial (só
#     achei referências de terceiros divergentes, SHA1 vs SHA256) — usa
#     RSA-SHA256/SHA256 aqui (padrão atual de documentos fiscais
#     eletrônicos mais recentes); o próprio validador de schema aceitou
#     sem reclamar da assinatura nos testes, então fica como está até
#     indicação em contrário.
#   - Dois bugs reais corrigidos iterando contra a homologação: (1) `dhEmi`
#     com "Z" (UTC) ao invés de offset explícito "+hh:mm" violava o
#     TSDateTimeUTC do schema; (2) `el()` escapava XML já montado como se
#     fosse texto puro, fazendo <prest> chegar com os filhos virando
#     "&lt;CNPJ&gt;..." — resolvido separando `el` (texto escapado) de
#     `grp` (contêiner, conteúdo já é XML, nunca escapa de novo).
#   - `cTribNac`/código de serviço: AINDA não validado de ponta a ponta —
#     o código usado aqui (6 dígitos: item+subitem LC116 + "00" de
#     desdobro) é um CHUTE educado, nunca confirmado contra a tabela
#     oficial, porque todo teste bateu primeiro no bloqueio abaixo antes
#     de chegar nessa validação.
#   - BLOQUEIO REAL ENCONTRADO (30/10/2026, 1 dia antes do prazo): o
#     convênio de cada município tem uma flag separada `aderenteEmissorNacional`
#     (ver `convenio_status` abaixo) — testei Guarulhos (3518800) e
#     Hortolândia (3519071): as DUAS retornam `aderenteEmissorNacional: 0`
#     (NÃO aderentes), enquanto São Paulo capital (3550308) e Americana
#     (3501004) retornam `1`. Ou seja: a obrigação legal pro CONTRIBUINTE
#     começa 01/11 independente da cidade, mas a PREFEITURA precisa ter
#     "ligado" o lado dela nesse convênio pra funcionar de verdade — e isso
#     já vem falhando/atrasando desde julho/2026 em Guarulhos (relatos
#     públicos de "cadastro não habilitado" em cada prorrogação anterior:
#     01/07, 01/08, 01/09). Sem essa flag em 1, nenhuma emissão real vai
#     funcionar nessa cidade, não importa o quão correta a DPS esteja.
#
# Uso: EmissorNacional::ProviderClient (provider_key 'emissor_nacional')
# chama este client com o tpAmb do estabelecimento (1 produção, 2
# homologação). `emitir_homologacao` continua existindo pra testes isolados.
#
# Atualização 24/11/2026: DPS conferida contra os XSDs oficiais (produção
# v1.01 de 09/02/2026 e produção restrita de 20/10/2026) e o Anexo I —
# cTribNac pela lista nacional, regras do Simples (pTotTribSN em vez de
# indTotTrib, regApTribSN) e IBSCBS opcional. Em homologação passa no
# schema e para em E0039 (Guarulhos não parametrizado pros emissores
# públicos nacionais nesse ambiente); produção só é ligada trocando o
# provider_key do estabelecimento, com autorização do usuário.
module EmissorNacional
  class Client
    class Error < StandardError; end

    Result = Struct.new(:success, :data, :error, :raw_response, keyword_init: true)

    HOMOLOGACAO_BASE = 'https://sefin.producaorestrita.nfse.gov.br/SefinNacional'.freeze
    PRODUCAO_BASE = 'https://sefin.nfse.gov.br/SefinNacional'.freeze
    # tpAmb do leiaute: 1 = produção, 2 = homologação (produção restrita).
    BASES = { '1' => PRODUCAO_BASE, '2' => HOMOLOGACAO_BASE }.freeze
    # ADN (sistema de parametrização, separado do Sefin Nacional acima) —
    # único jeito encontrado de checar se um município "ligou" o lado dele
    # do convênio (ver comentário no topo do arquivo).
    PARAMETRIZACAO_BASE = 'https://adn.producaorestrita.nfse.gov.br/parametrizacao'.freeze

    DSIG_NS = 'http://www.w3.org/2000/09/xmldsig#'.freeze
    C14N = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315'.freeze
    ENVELOPED = 'http://www.w3.org/2000/09/xmldsig#enveloped-signature'.freeze
    SHA256_NS = 'http://www.w3.org/2001/04/xmlenc#sha256'.freeze
    RSA_SHA256 = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256'.freeze

    def initialize(establishment:)
      @establishment = establishment
    end

    # Checa se um município "ligou" o convênio do Emissor Nacional —
    # chamar ANTES de tentar emitir pra evitar queimar um RPS à toa num
    # município que ainda não habilitou (ver comentário no topo do
    # arquivo). codigo_municipio: código IBGE de 7 dígitos; default é o do
    # estabelecimento. Retorna o hash `parametrosConvenio` cru, ou nil em
    # erro.
    def convenio_status(codigo_municipio = @establishment.municipio_ibge_code)
      uri = URI("#{PARAMETRIZACAO_BASE}/#{codigo_municipio}/convenio")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.cert = pkcs12.certificate
      http.key = pkcs12.key
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 15
      http.read_timeout = 15
      response = http.request(Net::HTTP::Get.new(uri.request_uri))
      return nil unless response.code.to_i == 200

      JSON.parse(response.body)['parametrosConvenio']
    rescue StandardError
      nil
    end

    # Só homologação, de propósito — ver comentário no topo do arquivo.
    def emitir_homologacao(invoice)
      dps_xml = dps_xml_homologacao(invoice)
      body = { dpsXmlGZipB64: gzip_base64(dps_xml) }.to_json

      response = post('/nfse', body)
      parse_response(response)
    end

    # DPS assinada (tpAmb=2), sem enviar — usada pra validar contra o XSD
    # oficial (DPS_v1.01.xsd) antes de qualquer chamada ao Sefin.
    def dps_xml_homologacao(invoice)
      sign(build_dps_xml(invoice, ambiente: '2'))
    end

    # ---------------------------------------------------- API (por ambiente)
    # tp_amb: '1' produção (sefin.nfse.gov.br) ou '2' homologação. Quem
    # decide é EmissorNacional::ProviderClient, a partir de
    # FiscalEstablishment#ambiente.

    # Assina e envia a DPS. Devolve [dps_xml_assinada, Result].
    def emitir_dps(invoice, tp_amb:)
      dps_xml = sign(build_dps_xml(invoice, ambiente: tp_amb))
      body = { dpsXmlGZipB64: gzip_base64(dps_xml) }.to_json
      [dps_xml, parse_response(post('/nfse', body, tp_amb: tp_amb))]
    end

    # Id da DPS (mesmo usado no atributo Id do infDPS) — serve pra consultar
    # se a NFS-e foi gerada quando a resposta da emissão se perdeu.
    def dps_id_for(invoice)
      dps_id(invoice.serie_rps, invoice.numero_rps)
    end

    # GET /dps/{id} -> chave de acesso (200) ou nil (404 = não gerada).
    def chave_por_dps(dps_id, tp_amb:)
      response = get("/dps/#{dps_id}", tp_amb: tp_amb)
      return nil if response.code.to_i == 404
      raise Error, "Consulta da DPS falhou (HTTP #{response.code}): #{response.body.to_s[0, 300]}" unless response.code.to_i == 200

      JSON.parse(response.body)['chaveAcesso'].presence
    end

    # GET /nfse/{chave} -> XML da NFS-e.
    def consultar_nfse(chave, tp_amb:)
      response = get("/nfse/#{chave}", tp_amb: tp_amb)
      raise Error, "Consulta da NFS-e falhou (HTTP #{response.code}): #{response.body.to_s[0, 300]}" unless response.code.to_i == 200

      gunzip_base64(JSON.parse(response.body)['nfseXmlGZipB64'])
    end

    # Evento 101101 (cancelamento). codigo: 1 erro na emissão, 2 serviço não
    # prestado, 9 outros (TSCodJustCanc). motivo: 15-255 caracteres.
    def cancelar_nfse(chave, tp_amb:, codigo: '9', motivo: 'Cancelamento solicitado pelo prestador')
      xml = sign_element(build_cancelamento_xml(chave, tp_amb: tp_amb, codigo: codigo, motivo: motivo), 'infPedReg')
      body = { pedidoRegistroEventoXmlGZipB64: gzip_base64(xml) }.to_json
      response = post("/nfse/#{chave}/eventos", body, tp_amb: tp_amb)
      parsed = begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end
      if response.code.to_i == 201
        Result.new(success: true, data: parsed.merge('eventoXml' => gunzip_base64(parsed['eventoXmlGZipB64'].to_s)),
                   raw_response: response.body)
      else
        Result.new(success: false, error: parsed['erros'] || parsed['erro'] || response.body.to_s[0, 500],
                   raw_response: response.body)
      end
    end

    # Código de Tributação Nacional (6 dígitos) — Anexo B da documentação
    # oficial (anexo_b-nbs2-lista_servico_nacional-snnfse-v1-01-20260122):
    # item(2) + subitem(2) + desdobro nacional(2). O desdobro NÃO é "00":
    # a lista nacional começa em "01" (ex.: 17.06 -> 170601, "Propaganda e
    # publicidade..."). Itens com mais de um desdobro precisam ser
    # escolhidos explicitamente; os usados pela empresa ficam aqui.
    # 17.02 fica de fora de propósito: tem 5 desdobros (170201 datilografia,
    # 170202 expediente/secretaria, ...), não dá pra escolher sem saber o
    # serviço — mapear quando a empresa usar.
    CODIGOS_TRIBUTACAO_NACIONAL = {
      '1701' => '170101',
      '1706' => '170601',
      '1008' => '100801',
      '1009' => '100901'
    }.freeze

    # NBS padrão por item (Anexo B / tabela de correlação item x NBS x
    # cIndOp x cClassTrib). 17.06 -> 1.1406.11.00 "Serviços de campanhas
    # publicitárias", que é o que a empresa presta (tráfego pago).
    CODIGOS_NBS_PADRAO = {
      '1706' => '114061100'
    }.freeze

    # Reforma Tributária (LC 214/2025) — valores da tabela oficial de
    # correlação (Anexo C / tabela da prefeitura) para prestação onerosa
    # nacional: cIndOp 100301 (local de incidência = domicílio do
    # adquirente), CST 000 / cClassTrib 000001 (tributação integral).
    # Para optante do Simples Nacional o grupo IBSCBS é OPCIONAL até 2027
    # (Anexo I, leiaute DPS, nota do campo IBSCBS) — por isso só vai na DPS
    # com NFSE_NACIONAL_IBSCBS_ENABLED ligado.
    IBSCBS_IND_OP_PADRAO = '100301'
    IBSCBS_CST_PADRAO = '000'
    IBSCBS_CLASS_TRIB_PADRAO = '000001'

    private

    # Situação perante o Simples Nacional (leiaute DPS, prest/regTrib/opSimpNac):
    # 1 = não optante, 2 = MEI, 3 = ME/EPP. Tem que bater com o cadastro do
    # Simples na competência, senão a DPS é rejeitada (E0160).
    def op_simp_nac
      case GlobalConfigService.load('ORG_REGIME_TRIBUTARIO', '').to_s
      when 'simples_nacional' then '3'
      when 'mei' then '2'
      else '1'
      end
    end

    def simples_me_epp?
      op_simp_nac == '3'
    end

    # Percentual aproximado de tributos do Simples Nacional (Lei
    # 12.741/2012). Para ME/EPP o leiaute PROÍBE indTotTrib (regra E0712) —
    # só aceita pTotTribSN (ou os percentuais detalhados). Valor vem do
    # contador: NFSE_PTOTTRIBSN, ex. "6.00".
    def p_tot_trib_sn
      value = GlobalConfigService.load('NFSE_PTOTTRIBSN', nil).to_s.tr(',', '.').strip
      raise Error, 'Configure NFSE_PTOTTRIBSN (percentual aproximado de tributos do Simples Nacional)' if value.blank?

      format('%.2f', value.to_f)
    end

    def ibscbs_enabled?
      ActiveModel::Type::Boolean.new.cast(GlobalConfigService.load('NFSE_NACIONAL_IBSCBS_ENABLED', false)) == true
    end

    def item_subitem(invoice)
      invoice.codigo_servico_municipal.to_s.gsub(/\D/, '')[0, 4]
    end

    def pkcs12
      @pkcs12 ||= @establishment.certificate_pkcs12
    end

    def prestador_cnpj
      @prestador_cnpj ||= begin
        subject = pkcs12.certificate.subject.to_s
        subject[/CN=[^\/]*?:(\d{14})/, 1] || subject[/\d{14}/]
      end
    end

    # ------------------------------------------------------------------ XML

    def dps_id(serie, numero)
      cod_mun = @establishment.municipio_ibge_code.to_s.rjust(7, '0')
      "DPS#{cod_mun}2#{prestador_cnpj}#{serie.to_s.rjust(5, '0')}#{numero.to_s.rjust(15, '0')}"
    end

    # Leiautes da DPS em uso (os dois são "versao=1.01" no XML, mas os XSDs
    # publicados divergem):
    #   - 'v1_01'        -> produção: nfse-esquemas_xsd-v1-01-20260209.zip
    #   - 'rtc_20261020' -> produção restrita (homologação):
    #                       esquemas_prod_restrita_20261020.zip
    # Diferenças que afetam esta DPS: finNFSe (infDPS no rtc, dentro de
    # IBSCBS no v1_01), ordem de xDescServ/cNBS em cServ, e o miolo de
    # IBSCBS/valores/trib. NFSE_NACIONAL_LAYOUT força um deles — virar pra
    # 'rtc_20261020' quando a produção adotar o leiaute novo.
    LAYOUTS = %w[v1_01 rtc_20261020].freeze

    def layout_for(ambiente)
      forced = GlobalConfigService.load('NFSE_NACIONAL_LAYOUT', nil).to_s
      return forced if LAYOUTS.include?(forced)

      ambiente.to_s == '2' ? 'rtc_20261020' : 'v1_01'
    end

    def rtc?
      @layout == 'rtc_20261020'
    end

    def build_dps_xml(invoice, ambiente:)
      @layout = layout_for(ambiente)
      serie = invoice.serie_rps
      numero = invoice.numero_rps
      id = dps_id(serie, numero)

      cabecalho = {
        'tpAmb' => ambiente,
        'dhEmi' => Time.now.in_time_zone('America/Sao_Paulo').strftime('%Y-%m-%dT%H:%M:%S%:z'),
        'verAplic' => 'AnuncioCertoCRM1.0',
        'serie' => serie.to_s,
        'nDPS' => numero.to_s,
        'dCompet' => Date.current.strftime('%Y-%m-%d'),
        'tpEmit' => '1'
      }
      # finNFSe (0 = regular): obrigatório no infDPS do leiaute rtc; no v1_01
      # ele só existe dentro de IBSCBS.
      cabecalho['finNFSe'] = '0' if rtc?
      cabecalho['cLocEmi'] = @establishment.municipio_ibge_code

      inf_dps = tag('infDPS', cabecalho.map { |k, v| el(k, v) }.join +
        grp('prest', prestador_xml) +
        grp('toma', tomador_xml(invoice)) +
        grp('serv', servico_xml(invoice)) +
        grp('valores', valores_xml(invoice)) +
        (ibscbs_enabled? ? grp('IBSCBS', ibscbs_xml) : ''),
        'Id' => id)

      '<?xml version="1.0" encoding="UTF-8"?>' \
      "<DPS xmlns=\"http://www.sped.fazenda.gov.br/nfse\" versao=\"1.01\">" \
      "#{inf_dps}" \
      "<Signature xmlns=\"#{DSIG_NS}\"></Signature>" \
      '</DPS>'
    end

    def prestador_xml
      cnpj_cpf_xml(prestador_cnpj) +
        el('IM', @establishment.inscricao_municipal) +
        grp('regTrib',
            el('opSimpNac', op_simp_nac) +
            # 1 = tributos federais e municipal apurados pelo Simples (caso
            # normal, sem sublimite estourado). Proibido pra não optante/MEI (E0162).
            (simples_me_epp? ? el('regApTribSN', '1') : '') +
            el('regEspTrib', '0'))
    end

    # Grupo IBSCBS (TCRTCInfoIBSCBS). Diferente do leiaute GISS/ABRASF, aqui
    # NÃO vão cLocalidadeIncid/pRedutor/vBC — o Sefin calcula e devolve na
    # NFS-e. Miolo por leiaute:
    #   v1_01: finNFSe, indFinal?, cIndOp, indDest, valores>trib>gIBSCBS>{CST,cClassTrib}
    #   rtc:   indFinal?, cIndOp?, indDest, valores>trib>{CST,cClassTrib}
    def ibscbs_xml
      classificacao = el('CST', IBSCBS_CST_PADRAO) + el('cClassTrib', IBSCBS_CLASS_TRIB_PADRAO)
      (rtc? ? '' : el('finNFSe', '0')) +
        el('indFinal', '0') +
        el('cIndOp', IBSCBS_IND_OP_PADRAO) +
        el('indDest', '0') +
        grp('valores', grp('trib', rtc? ? classificacao : grp('gIBSCBS', classificacao)))
    end

    def tomador_xml(invoice)
      endereco = invoice.tomador_endereco || {}
      cnpj_cpf_xml(invoice.tomador_cpf_cnpj) +
        el('xNome', invoice.tomador_nome) +
        grp('end', endereco_xml(endereco)) +
        el('email', invoice.tomador_email)
    end

    def endereco_xml(endereco)
      grp('endNac',
          el('cMun', endereco['codigo_municipio']) +
          el('CEP', endereco['cep'].to_s.gsub(/\D/, ''))) +
        el('xLgr', endereco['logradouro']) +
        el('nro', endereco['numero']) +
        el('xBairro', endereco['bairro'])
    end

    def servico_xml(invoice)
      grp('locPrest', el('cLocPrestacao', @establishment.municipio_ibge_code)) +
        grp('cServ',
            el('cTribNac', codigo_tributacao_nacional(invoice)) +
            # Ordem muda entre leiautes: v1_01 = xDescServ, cNBS; rtc = cNBS, xDescServ.
            (rtc? ? el('cNBS', codigo_nbs(invoice)) + el('xDescServ', invoice.discriminacao)
                  : el('xDescServ', invoice.discriminacao) + el('cNBS', codigo_nbs(invoice))))
    end

    # Ver CODIGOS_TRIBUTACAO_NACIONAL. Item sem mapeamento é recusado em vez
    # de chutar o desdobro — um cTribNac errado emite nota com o serviço
    # errado, não dá erro.
    def codigo_tributacao_nacional(invoice)
      item = item_subitem(invoice)
      CODIGOS_TRIBUTACAO_NACIONAL[item] ||
        raise(Error, "Código de tributação nacional não mapeado para o item #{invoice.codigo_servico_municipal} " \
                     '(ver CODIGOS_TRIBUTACAO_NACIONAL / Anexo B)')
    end

    def codigo_nbs(invoice)
      (invoice.codigo_nbs.presence || CODIGOS_NBS_PADRAO[item_subitem(invoice)]).to_s.gsub(/\D/, '').presence
    end

    def valores_xml(invoice)
      grp('vServPrest', el('vServ', amount(invoice.valor_servicos))) +
        grp('trib',
            grp('tribMun',
                el('tribISSQN', '1') +
                el('tpRetISSQN', '1') +
                el('pAliq', format('%.2f', invoice.aliquota_iss_pct.to_f))) +
            # ME/EPP: indTotTrib é proibido (E0712) — informa pTotTribSN.
            grp('totTrib', simples_me_epp? ? el('pTotTribSN', p_tot_trib_sn) : el('indTotTrib', '0')))
    end

    def cnpj_cpf_xml(digits)
      digits = digits.to_s.gsub(/\D/, '')
      digits.length > 11 ? el('CNPJ', digits) : el('CPF', digits)
    end

    # Elemento-folha com TEXTO (escapado) — ex. <serie>9</serie>.
    def el(name, value)
      return '' if value.nil? || value.to_s.empty?

      "<#{name}>#{escape_xml(value)}</#{name}>"
    end

    # Elemento-CONTÊINER cujo conteúdo já é XML montado por grp/el — NUNCA
    # escapa `inner` (diferente de `el`), senão o XML interno vira texto
    # (bug real encontrado testando contra homologação: <prest> chegava
    # com os filhos inteiros escapados como &lt;CNPJ&gt;...).
    def grp(name, inner)
      "<#{name}>#{inner}</#{name}>"
    end

    def tag(name, inner, attrs = {})
      attrs_str = attrs.map { |k, v| %( #{k}="#{escape_xml(v)}") }.join
      "<#{name}#{attrs_str}>#{inner}</#{name}>"
    end

    def escape_xml(value)
      value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
    end

    def amount(value)
      format('%.2f', value.to_f)
    end

    # ------------------------------------------------------------ ASSINATURA

    # Enveloped XMLDSig sobre o nó <infDPS Id="...">, <Signature> como irmã
    # (mesmo padrão sign/sign_one de Guarulhos::Client, adaptado pra
    # SHA256). Algoritmo não confirmado contra doc oficial — ver comentário
    # no topo do arquivo.
    def sign(xml_string)
      sign_element(xml_string, 'infDPS')
    end

    # Mesma assinatura pra qualquer documento do leiaute: referencia o Id do
    # elemento `element_name` (infDPS na DPS, infPedReg no pedido de evento).
    def sign_element(xml_string, element_name)
      doc = Nokogiri::XML(xml_string)
      signature = doc.at_xpath("//*[local-name()='Signature']")
      inf_dps = doc.at_xpath("//*[local-name()='#{element_name}']")
      id = inf_dps['Id']

      digest = OpenSSL::Digest::SHA256.digest(inf_dps.canonicalize)

      signature.inner_html = signed_info_and_key_info(id, digest)
      signed_info = signature.at_xpath("./*[local-name()='SignedInfo']")
      signature_value = pkcs12.key.sign(OpenSSL::Digest.new('SHA256'), signed_info.canonicalize)
      signature.at_xpath("./*[local-name()='SignatureValue']").content = Base64.strict_encode64(signature_value)

      doc.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    def signed_info_and_key_info(id, digest)
      '<SignedInfo>' \
        "<CanonicalizationMethod Algorithm=\"#{C14N}\"/>" \
        "<SignatureMethod Algorithm=\"#{RSA_SHA256}\"/>" \
        "<Reference URI=\"##{id}\">" \
          '<Transforms>' \
            "<Transform Algorithm=\"#{ENVELOPED}\"/>" \
            "<Transform Algorithm=\"#{C14N}\"/>" \
          '</Transforms>' \
          "<DigestMethod Algorithm=\"#{SHA256_NS}\"/>" \
          "<DigestValue>#{Base64.strict_encode64(digest)}</DigestValue>" \
        '</Reference>' \
      '</SignedInfo>' \
      '<SignatureValue></SignatureValue>' \
      '<KeyInfo>' \
        "<X509Data><X509Certificate>#{Base64.strict_encode64(pkcs12.certificate.to_der)}</X509Certificate></X509Data>" \
      '</KeyInfo>'
    end

    # --------------------------------------------------------------- HTTP

    def gzip_base64(xml_string)
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write(xml_string)
      gz.close
      Base64.strict_encode64(io.string)
    end

    def gunzip_base64(b64)
      Zlib::GzipReader.new(StringIO.new(Base64.decode64(b64))).read
    end

    def http_for(path, tp_amb)
      base = BASES.fetch(tp_amb.to_s) { raise Error, "tpAmb inválido: #{tp_amb.inspect}" }
      uri = URI("#{base}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.cert = pkcs12.certificate
      http.key = pkcs12.key
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 20
      http.read_timeout = 30
      [http, uri]
    end

    def post(path, body, tp_amb: '2')
      http, uri = http_for(path, tp_amb)
      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      http.request(request, body)
    end

    def get(path, tp_amb:)
      http, uri = http_for(path, tp_amb)
      request = Net::HTTP::Get.new(uri.request_uri)
      request['Accept'] = 'application/json'
      http.request(request)
    end

    # Pedido de registro do evento 101101 (cancelamento) —
    # tiposEventos_v1.01.xsd: pedRegEvento > infPedReg(Id) > tpAmb, verAplic,
    # dhEvento, CNPJAutor, chNFSe, e101101{xDesc, cMotivo, xMotivo}.
    # Id = "PRE" + chave(50) + tipo do evento(6).
    def build_cancelamento_xml(chave, tp_amb:, codigo:, motivo:)
      inf = tag('infPedReg',
                el('tpAmb', tp_amb) +
                el('verAplic', 'AnuncioCertoCRM1.0') +
                el('dhEvento', Time.now.in_time_zone('America/Sao_Paulo').strftime('%Y-%m-%dT%H:%M:%S%:z')) +
                el('CNPJAutor', prestador_cnpj) +
                el('chNFSe', chave) +
                grp('e101101',
                    el('xDesc', 'Cancelamento de NFS-e') +
                    el('cMotivo', codigo) +
                    el('xMotivo', motivo.to_s.strip.ljust(15, '.')[0, 255])),
                'Id' => "PRE#{chave}101101")

      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<pedRegEvento xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01">' \
      "#{inf}" \
      "<Signature xmlns=\"#{DSIG_NS}\"></Signature>" \
      '</pedRegEvento>'
    end

    def parse_response(response)
      parsed = JSON.parse(response.body)

      if response.code.to_i == 201
        parsed['nfseXml'] = gunzip_base64(parsed['nfseXmlGZipB64']) if parsed['nfseXmlGZipB64']
        Result.new(success: true, data: parsed, raw_response: response.body)
      else
        Result.new(success: false, error: parsed['erros'] || parsed, raw_response: response.body)
      end
    rescue JSON::ParserError
      Result.new(success: false, error: "resposta não-JSON (HTTP #{response.code}): #{response.body[0..500]}", raw_response: response.body)
    end
  end
end
