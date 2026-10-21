# Gera o DANFSe (documento auxiliar da NFS-e) em PDF a partir dos dados já
# salvos no ServiceInvoice — sem depender de nenhum portal público da
# prefeitura (cuja URL de consulta não é documentada de forma confiável
# pra Guarulhos). Só os dados do PRESTADOR vêm do `xml_retorno` (razão
# social, nome fantasia, CNPJ, endereço): é o único lugar que os tem — o
# `FiscalEstablishment` guarda certificado + inscrição municipal, não razão
# social. O resto (tomador, valores, discriminação) já está em colunas
# próprias do ServiceInvoice, não precisa parsear XML de novo.
#
# Layout simplificado (não é cópia do leiaute oficial da Nota Técnica
# 008/2026 do DANFSe nacional) — mas traz todo dado fiscalmente relevante
# e o código de verificação, suficiente pra cliente entender/validar a
# nota. Só pode ser chamado pra nota `authorized` (sem isso não existe
# `xml_retorno` com os dados do prestador).
module ServiceInvoices
  class DanfsePdfService
    class Error < StandardError; end

    def self.call(invoice)
      new(invoice).call
    end

    def initialize(invoice)
      @invoice = invoice
      raise Error, 'NFS-e ainda não autorizada — sem dados da prefeitura pra gerar o PDF' unless invoice.authorized?

      @doc = Nokogiri::XML(invoice.xml_retorno.to_s)
    end

    def call
      Prawn::Document.new(page_size: 'A4', margin: 36) do |pdf|
        render_header(pdf)
        render_identificacao(pdf)
        render_prestador(pdf)
        render_tomador(pdf)
        render_servico(pdf)
        render_valores(pdf)
        render_rodape(pdf)
      end.render
    end

    private

    attr_reader :invoice, :doc

    # Busca por `local-name()` em vez de registrar o namespace `ns2` — a
    # Giss usa um namespace diferente por versão de schema
    # (`nfse-v2_04.xsd`, `tipos-v2_04.xsd`...) e o prefixo real às vezes
    # muda; `local-name()` ignora tudo isso e sempre acha o elemento certo.
    def find_text(xpath)
      doc.at_xpath(xpath)&.text
    end

    def prestador_servico_node
      @prestador_servico_node ||= doc.at_xpath("//*[local-name()='PrestadorServico']")
    end

    def prestador_identificacao_node
      @prestador_identificacao_node ||= doc.at_xpath("//*[local-name()='DeclaracaoPrestacaoServico']//*[local-name()='Prestador']")
    end

    def render_header(pdf)
      pdf.text 'DANFSe', size: 16, style: :bold, align: :center
      pdf.text 'Documento Auxiliar da Nota Fiscal de Serviços Eletrônica', size: 9, align: :center, color: '555555'
      pdf.move_down 4
      pdf.stroke_horizontal_rule
      pdf.move_down 10
    end

    def render_identificacao(pdf)
      numero = find_text("//*[local-name()='Nfse']/*[local-name()='InfNfse']/*[local-name()='Numero']") || invoice.numero_nfse
      data_emissao = find_text("//*[local-name()='InfNfse']/*[local-name()='DataEmissao']")

      pdf.table(
        [
          ['NFS-e nº', numero.to_s, 'RPS', "#{invoice.serie_rps}/#{invoice.numero_rps}"],
          ['Data de emissão', format_datetime(data_emissao), 'Código de verificação', invoice.codigo_verificacao.to_s],
        ],
        width: pdf.bounds.width,
        cell_style: { size: 8, padding: 4 },
      ) do |table|
        table.columns(0).font_style = :bold
        table.columns(2).font_style = :bold
      end
      pdf.move_down 10
    end

    def render_prestador(pdf)
      razao_social = prestador_servico_node&.at_xpath(".//*[local-name()='RazaoSocial']")&.text
      nome_fantasia = prestador_servico_node&.at_xpath(".//*[local-name()='NomeFantasia']")&.text
      cnpj = prestador_identificacao_node&.at_xpath(".//*[local-name()='Cnpj']")&.text
      inscricao = prestador_identificacao_node&.at_xpath(".//*[local-name()='InscricaoMunicipal']")&.text
      endereco_node = prestador_servico_node&.at_xpath(".//*[local-name()='Endereco']")

      section_title(pdf, 'Prestador do Serviço')
      pdf.text "#{razao_social}#{" (#{nome_fantasia})" if nome_fantasia.present? && nome_fantasia != razao_social}", size: 9, style: :bold
      pdf.text "CNPJ: #{format_cnpj(cnpj)}  ·  Inscrição Municipal: #{inscricao}", size: 8
      pdf.text format_endereco_node(endereco_node), size: 8 if endereco_node
      pdf.move_down 8
    end

    def render_tomador(pdf)
      endereco = invoice.tomador_endereco || {}

      section_title(pdf, 'Tomador do Serviço')
      pdf.text invoice.tomador_nome.to_s, size: 9, style: :bold
      pdf.text "CPF/CNPJ: #{format_cpf_cnpj(invoice.tomador_cpf_cnpj)}", size: 8
      pdf.text invoice.tomador_email, size: 8 if invoice.tomador_email.present?
      pdf.text format_endereco_hash(endereco), size: 8 if endereco.present?
      pdf.move_down 8
    end

    def render_servico(pdf)
      section_title(pdf, 'Discriminação do Serviço')
      pdf.text invoice.discriminacao.to_s, size: 8.5
      pdf.text "Código do serviço (LC 116): #{invoice.codigo_servico_municipal}", size: 8, color: '555555'
      pdf.move_down 8
    end

    def render_valores(pdf)
      section_title(pdf, 'Valores')
      pdf.table(
        [
          ['Valor dos serviços', 'Deduções', 'Alíquota ISS', 'Valor ISS', 'Valor líquido'],
          [
            format_money(invoice.valor_servicos),
            format_money(invoice.valor_deducoes),
            "#{format_number(invoice.aliquota_iss_pct)}%",
            format_money(invoice.valor_iss),
            format_money(invoice.valor_servicos.to_f - invoice.valor_deducoes.to_f),
          ],
        ],
        width: pdf.bounds.width,
        cell_style: { size: 8, padding: 4, align: :center },
      ) do |table|
        table.row(0).font_style = :bold
        table.row(0).background_color = 'EEEEEE'
      end
      pdf.move_down 10
    end

    def render_rodape(pdf)
      pdf.stroke_horizontal_rule
      pdf.move_down 6
      pdf.text "Protocolo: #{invoice.protocolo}  ·  Código de verificação: #{invoice.codigo_verificacao}", size: 7.5, color: '555555'
      pdf.text(
        'Este é um documento auxiliar gerado a partir dos dados autorizados pela prefeitura — ' \
        'não substitui a NFS-e eletrônica. A autenticidade pode ser conferida diretamente no portal ' \
        'da prefeitura do município de prestação do serviço, usando o protocolo e o código de verificação acima.',
        size: 7, color: '777777',
      )
    end

    def section_title(pdf, text)
      pdf.text text, size: 9, style: :bold, color: '333333'
      pdf.move_down 2
    end

    def format_datetime(iso)
      return '—' if iso.blank?

      Time.zone.parse(iso).strftime('%d/%m/%Y %H:%M')
    rescue ArgumentError, TypeError
      iso
    end

    def format_money(value)
      ActiveSupport::NumberHelper.number_to_currency(value.to_f, unit: 'R$ ', separator: ',', delimiter: '.')
    end

    def format_number(value)
      ActiveSupport::NumberHelper.number_to_rounded(value.to_f, precision: 2, separator: ',')
    end

    def format_cnpj(cnpj)
      return '—' if cnpj.blank?

      cnpj.gsub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
    end

    def format_cpf_cnpj(value)
      digits = value.to_s.gsub(/\D/, '')
      return format_cnpj(digits) if digits.length == 14

      digits.gsub(/(\d{3})(\d{3})(\d{3})(\d{2})/, '\1.\2.\3-\4')
    end

    def format_endereco_node(node)
      return '' unless node

      logradouro = node.at_xpath(".//*[local-name()='Endereco']")&.text
      numero = node.at_xpath(".//*[local-name()='Numero']")&.text
      bairro = node.at_xpath(".//*[local-name()='Bairro']")&.text
      uf = node.at_xpath(".//*[local-name()='Uf']")&.text
      cep = node.at_xpath(".//*[local-name()='Cep']")&.text
      [[logradouro, numero].compact.join(', '), bairro, [format_cep(cep), uf].compact.join(' - ')].reject(&:blank?).join(' · ')
    end

    def format_endereco_hash(endereco)
      endereco = endereco.with_indifferent_access
      [
        [endereco[:logradouro], endereco[:numero]].compact.join(', '),
        endereco[:bairro],
        [format_cep(endereco[:cep]), endereco[:uf]].compact.join(' - '),
      ].reject(&:blank?).join(' · ')
    end

    def format_cep(cep)
      return nil if cep.blank?

      cep.to_s.gsub(/(\d{5})(\d{3})/, '\1-\2')
    end
  end
end
