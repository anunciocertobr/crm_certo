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
# IMPORTANTE: só tem o método `emitir_homologacao`, de propósito — força
# tpAmb=2 (Homologação) e aponta pro host de produção restrita, nunca pro
# de produção real. NÃO está plugado em FiscalEstablishment#provider_client
# (nenhuma nota real passa por aqui ainda) até: 1) confirmar
# `aderenteEmissorNacional: 1` pro município do estabelecimento, 2)
# validar o cTribNac certo, 3) completar um teste de emissão de ponta a
# ponta em homologação, e 4) o usuário autorizar ligar pra valer.
module EmissorNacional
  class Client
    class Error < StandardError; end

    Result = Struct.new(:success, :data, :error, :raw_response, keyword_init: true)

    HOMOLOGACAO_BASE = 'https://sefin.producaorestrita.nfse.gov.br/SefinNacional'.freeze
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
      dps_xml = sign(build_dps_xml(invoice, ambiente: '2'))
      body = { dpsXmlGZipB64: gzip_base64(dps_xml) }.to_json

      response = post('/nfse', body)
      parse_response(response)
    end

    private

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

    def build_dps_xml(invoice, ambiente:)
      serie = invoice.serie_rps
      numero = invoice.numero_rps
      id = dps_id(serie, numero)

      inf_dps = tag('infDPS', {
        'tpAmb' => ambiente,
        'dhEmi' => Time.now.in_time_zone('America/Sao_Paulo').strftime('%Y-%m-%dT%H:%M:%S%:z'),
        'verAplic' => 'AnuncioCertoCRM1.0',
        'serie' => serie.to_s,
        'nDPS' => numero.to_s,
        'dCompet' => Date.current.strftime('%Y-%m-%d'),
        'tpEmit' => '1',
        'finNFSe' => '0',
        'cLocEmi' => @establishment.municipio_ibge_code
      }.map { |k, v| el(k, v) }.join +
        grp('prest', prestador_xml) +
        grp('toma', tomador_xml(invoice)) +
        grp('serv', servico_xml(invoice)) +
        grp('valores', valores_xml(invoice)),
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
        grp('regTrib', el('opSimpNac', '3') + el('regEspTrib', '0'))
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
            el('xDescServ', invoice.discriminacao) +
            el('cNBS', invoice.codigo_nbs.presence))
    end

    # cTribNac: 6 dígitos (2 item + 2 subitem LC116 + 2 desdobro nacional,
    # default "00" quando o município não tem desdobro próprio) — invoice
    # guarda só "17.06" (item.subitem); monta os 6 dígitos com desdobro 00.
    def codigo_tributacao_nacional(invoice)
      "#{invoice.codigo_servico_municipal.to_s.gsub(/\D/, '').ljust(4, '0')}00"
    end

    def valores_xml(invoice)
      grp('vServPrest', el('vServ', amount(invoice.valor_servicos))) +
        grp('trib',
            grp('tribMun',
                el('tribISSQN', '1') +
                el('tpRetISSQN', '1') +
                el('pAliq', format('%.2f', invoice.aliquota_iss_pct.to_f))) +
            grp('totTrib', el('indTotTrib', '0')))
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
      doc = Nokogiri::XML(xml_string)
      signature = doc.at_xpath("//*[local-name()='Signature']")
      inf_dps = doc.at_xpath("//*[local-name()='infDPS']")
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

    def post(path, body)
      uri = URI("#{HOMOLOGACAO_BASE}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.cert = pkcs12.certificate
      http.key = pkcs12.key
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 20
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      http.request(request, body)
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
