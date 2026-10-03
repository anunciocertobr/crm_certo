# frozen_string_literal: true

# Serialização do relatório de Google Ads no formato que a aba do relatório
# espera (chaves em português).
#
# Mesma razão do MetaInsightsRowSerializer: a rota autenticada
# /reports/google_ads/insights e a rota pública do link compartilhado precisam
# devolver exatamente o mesmo JSON, senão o cliente vê números com cara
# diferente dos do dono da conta.
module GoogleAdsReportSerializer
  MICROS = 1_000_000.0

  module_function

  def build(campaign_rows:, terms_by_impressions: [], terms_by_clicks: [])
    campaigns = Array(campaign_rows).map { |row| campaign(row) }

    {
      totals: totals(campaigns),
      campaigns: campaigns,
      top_terms_by_impressions: Array(terms_by_impressions).map { |row| term(row) },
      top_terms_by_clicks: Array(terms_by_clicks).map { |row| term(row) }
    }
  end

  def campaign(row)
    campaign = row['campaign'] || {}
    metrics = row['metrics'] || {}

    {
      campanha: campaign['name'],
      status: campaign['status'],
      cliques: metrics['clicks'].to_i,
      impressoes: metrics['impressions'].to_i,
      custo: (metrics['costMicros'].to_i / MICROS).round(2),
      conversoes: metrics['conversions'].to_f.round(2)
    }
  end

  def term(row)
    search_term_view = row['searchTermView'] || {}
    campaign = row['campaign'] || {}
    metrics = row['metrics'] || {}

    {
      termo: search_term_view['searchTerm'],
      campanha: campaign['name'],
      impressoes: metrics['impressions'].to_i,
      cliques: metrics['clicks'].to_i
    }
  end

  def totals(campaigns)
    {
      cost: campaigns.sum { |c| c[:custo] }.round(2),
      clicks: campaigns.sum { |c| c[:cliques] },
      impressions: campaigns.sum { |c| c[:impressoes] },
      conversions: campaigns.sum { |c| c[:conversoes] }.round(2)
    }
  end
end