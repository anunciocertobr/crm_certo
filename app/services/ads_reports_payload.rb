# frozen_string_literal: true

# Monta o payload do link público de relatório de anúncios.
#
# Este serviço é o ÚNICO lugar onde o escopo do link vira chamada de API. A
# lista de contas vem de `link.ad_account_ids` — ou seja, do que foi gravado na
# criação do link pelo dono da conta — e nunca de parâmetro vindo do visitante.
# Se alguém pudesse escolher as contas na URL, trocaria o id e leria as contas
# dos outros clientes, que é exatamente o que o link precisa impedir.
module AdsReportsPayload
  DEFAULT_RANGE_DAYS = 30

  Outcome = Struct.new(:success, :data, :error, keyword_init: true)

  module_function

  # date_start/date_stop chegam do front (a página deixa o cliente escolher o
  # período), então são validados de verdade: sem teto, alguém pede 10 anos e
  # a requisição morre no timeout.
  def resolve_range(date_start, date_stop)
    stop = parse_date(date_stop) || Date.current
    start = parse_date(date_start) || (stop - (DEFAULT_RANGE_DAYS - 1).days)

    start = stop - (DEFAULT_RANGE_DAYS - 1).days if (stop - start).to_i > ReportSnapshot::MAX_RANGE_DAYS
    start = stop - (DEFAULT_RANGE_DAYS - 1).days if start > stop

    [start, stop]
  end

  def call(link, date_start: nil, date_stop: nil, conteudo: 'geral')
    range_start, range_stop = resolve_range(date_start, date_stop)

    meta_accounts = link.ad_account_ids.map do |account_id|
      rows = meta_rows(account_id, range_start, range_stop, conteudo)
      {
        'id' => account_id,
        'name' => account_name(account_id),
        'rows' => rows,
        'totals' => totals(rows)
      }
    end

    Outcome.new(
      success: true,
      data: {
        'range' => { 'date_start' => range_start.to_s, 'date_stop' => range_stop.to_s },
        'meta' => meta_accounts,
        'google_ads' => link.include_google_ads? ? google_ads(range_start, range_stop) : nil,
        'ga4' => link.include_ga4? ? ga4(range_start, range_stop) : nil
      }
    )
  end

  def parse_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Cada conta é uma chamada à Graph API. Uma conta que falhou (token
  # expirado, permissão removida) não pode derrubar o relatório inteiro — o
  # cliente ainda precisa ver as outras contas que ele escolheu, e o erro fica
  # explícito no bloco em vez de virar página branca.
  def meta_rows(account_id, date_start, date_stop, conteudo)
    result = Meta::AdsInsightsService.new.campaign_insights(
      ad_account_id: account_id,
      conteudo: conteudo,
      date_start: date_start.to_s,
      date_stop: date_stop.to_s
    )

    unless result.success
      Rails.logger.warn("[AdsReportsPayload] insights falhou account=#{account_id}: #{result.error}")
      return []
    end

    Array(result.data).map { |row| MetaInsightsRowSerializer.serialize(row, conteudo) }
  rescue StandardError => e
    Rails.logger.warn("[AdsReportsPayload] exception account=#{account_id}: #{e.class}: #{e.message}")
    []
  end

  def account_name(account_id)
    # O nome vem da meta de MarketingClientGoal quando a conta é conhecida
    # (barato, já está no banco). Conta sem meta cai no id — melhor mostrar o
    # id do que chamar a Graph API só para rotular uma linha.
    goal = MarketingClientGoal.all.find do |g|
      Array(g.ad_accounts).any? { |a| a['id'].to_s == account_id.to_s }
    end
    acc = Array(goal&.ad_accounts).find { |a| a['id'].to_s == account_id.to_s }
    acc&.dig('name').presence || account_id.to_s
  end

  # Somatório das linhas por chave. 'Gasto', 'CPC' etc. são strings em formato
  # pt-BR na serialização, então só somam os campos que são número de verdade
  # — custo por resultado é recalculado a partir do gasto somado, senão sairia
  # média de média.
  def totals(rows)
    spend_total = rows.sum { |r| r['Gasto'].to_s.tr(',', '.').to_f }
    {
      'Gasto' => format('%.2f', spend_total).tr('.', ','),
      'Impressões' => rows.sum { |r| r['Impressões'].to_i },
      'Alcance' => rows.sum { |r| r['Alcance'].to_i },
      'Cliques' => rows.sum { |r| r['Cliques'].to_i },
      'Mensagens' => rows.sum { |r| r['Mensagens'].to_i },
      'Leads do Pixel' => rows.sum { |r| r['Leads do Pixel'].to_i },
      'Leads do Meta Ads' => rows.sum { |r| r['Leads do Meta Ads'].to_i }
    }
  end

  def google_ads(date_start, date_stop)
    service = Google::AdsInsightsService.new
    return nil unless service.connected?

    campaigns = service.campaigns(date_start: date_start.to_s, date_stop: date_stop.to_s)
    cost = service.account_cost(date_start: date_start.to_s, date_stop: date_stop.to_s)

    # Sem `customer_id` configurado a integração responde 404 em
    # /customers//googleAds:search. Um bloco vazio na tela do cliente parece
    # "não teve resultado", que é mentira — é configuração faltando. Melhor
    # não mostrar o bloco e deixar o aviso ficar nos logs.
    return nil unless campaigns.success

    { 'campaigns' => campaigns.data, 'cost' => cost.success ? cost.data : nil }
  rescue StandardError => e
    Rails.logger.warn("[AdsReportsPayload] google_ads falhou: #{e.class}: #{e.message}")
    nil
  end

  def ga4(date_start, date_stop)
    service = Google::AnalyticsInsightsService.new
    return nil unless service.connected?

    property_id = service.list_properties.data&.first&.dig('property_id')
    return nil if property_id.blank?

    {
      'property_id' => property_id,
      'overview' => service.traffic_overview(
        property_id: property_id, date_start: date_start.to_s, date_stop: date_stop.to_s
      ).data,
      'by_channel' => service.traffic_by_channel(
        property_id: property_id, date_start: date_start.to_s, date_stop: date_stop.to_s
      ).data
    }
  rescue StandardError => e
    Rails.logger.warn("[AdsReportsPayload] ga4 falhou: #{e.class}: #{e.message}")
    nil
  end
end