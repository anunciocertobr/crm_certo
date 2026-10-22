# Cria o GoodsInvoice (sempre, mesmo sem provedor configurado — os dados
# fiscais reais da operação ficam registrados) e tenta transmitir pra SEFAZ
# através do provider_client do perfil. Sem provedor contratado, isso
# levanta GoodsInvoices::ProviderClient::Error (ver
# UnconfiguredProviderClient) — a nota fica salva como `pending` com o
# motivo em erro_mensagem, nunca como `authorized` fingindo sucesso.
#
# O imposto de cada item usa Tax::CalculationService (o mesmo de
# /products/:id/calcular_imposto) — nada de recalcular IBS/CBS/Imposto
# Seletivo/legado na mão aqui, pra não ter duas fórmulas divergentes no
# mesmo CRM quando a alíquota de teste mudar (GlobalConfig).
module GoodsInvoices
  class EmissionService
    def initialize(fiscal_profile:)
      @profile = fiscal_profile
    end

    def call(attrs)
      invoice = ActiveRecord::Base.transaction do
        invoice = build_invoice(attrs)
        invoice.save!
        invoice
      end
      transmitir(invoice)
      invoice
    end

    private

    def build_invoice(attrs)
      itens = Array(attrs[:itens]).map { |item| item_com_impostos(item) }
      agregados = agregar_impostos(itens)
      valor_produtos = itens.sum { |i| BigDecimal(i[:valor_total].to_s) }
      desconto = BigDecimal(attrs[:valor_desconto].presence || '0')
      frete = BigDecimal(attrs[:valor_frete].presence || '0')

      @profile.goods_invoices.new(
        attrs.merge(
          itens: itens,
          numero: @profile.next_numero!(attrs[:modelo]).to_s,
          serie: @profile.serie_for(attrs[:modelo]),
          valor_produtos: valor_produtos,
          valor_total: valor_produtos - desconto + frete,
          **agregados
        )
      )
    end

    # Calcula o imposto do item via produto real quando `product_id` vier
    # (fonte de verdade do NCM/CFOP/CST/CSOSN/redução); sem produto vinculado
    # não dá pra rodar Tax::CalculationService (ele exige um Product) — o
    # item fica sem bloco de impostos e isso aparece nos avisos agregados.
    def item_com_impostos(item)
      item = item.to_h.with_indifferent_access
      product = Product.find_by(id: item[:product_id])
      return item.merge(impostos: nil, avisos: ['Item sem produto vinculado — imposto não calculado.']) unless product

      resultado = Tax::CalculationService.new(
        product: product, quantity: item[:quantidade], unit_price: item[:valor_unitario]
      ).calculate

      item.merge(impostos: resultado.to_h, avisos: resultado.avisos)
    end

    def agregar_impostos(itens)
      com_imposto = itens.select { |i| i[:impostos] }
      avisos = itens.flat_map { |i| i[:avisos] || [] }.uniq

      {
        regime_tributario: com_imposto.first&.dig(:impostos, :regime),
        valor_cbs: somar(com_imposto, :cbs_valor),
        valor_ibs: somar(com_imposto, :ibs_valor),
        valor_imposto_seletivo: somar(com_imposto, :imposto_seletivo_valor),
        valor_legado: somar(com_imposto, :legado_valor),
        valor_total_impostos: somar(com_imposto, :total_impostos),
        avisos_fiscais: avisos
      }
    end

    def somar(itens, campo)
      itens.sum { |i| BigDecimal(i.dig(:impostos, campo).to_s) }
    end

    def transmitir(invoice)
      @profile.provider_client.emitir(invoice)
    rescue ProviderClient::Error => e
      invoice.update!(erro_mensagem: e.message)
    end
  end
end
