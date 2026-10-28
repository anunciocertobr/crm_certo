# Porte pra Ruby de calcMetrics/averageByDay/groupByObjective do
# public/report-pdf.v2.js (evo-ai-frontend-community) — usado pelo PDF
# agendado (Reports::MetaAdsPdfService), que roda no servidor sem
# navegador. Mesmas fórmulas: se um dia mudarem lá, têm que mudar aqui
# também.
#
# Opera em LINHAS CRUAS da Graph API (Meta::AdsInsightsService#campaign_
# insights), não nas linhas já formatadas em português por
# MetaInsightsRowSerializer — mas reaproveita ACTION_TYPES/tally_actions
# de lá pra tabular mensagens/leads/compras a partir de `actions`, que é
# a mesma fonte usada pelo serializer.
#
# Mapeamento confirmado lendo o HTML armazenado do relatório
# (META_METRIC_CONFIG + normalizeMetaAdsDataItem): spent=Gasto (row.spend),
# clicks=Cliques (actions[:link_click], NÃO o campo cru `clicks` da Graph
# API), leads=Leads do Meta Ads (actions[:leads_ads], ação 'lead' —
# diferente de leads_pixel), messages=Mensagens (actions[:mensagens]),
# purchases=Compras (actions[:compras]).
module Reports
  module MetaAdsAggregationService
    module_function

    BASE_METRICS = %i[spent impressions reach clicks messages leads purchases].freeze

    def calc_metrics(rows)
      totals = Hash.new(0.0)
      rows.each do |row|
        actions = MetaInsightsRowSerializer.tally_actions(row['actions'])
        totals[:spent] += row['spend'].to_f
        totals[:impressions] += row['impressions'].to_f
        totals[:reach] += row['reach'].to_f
        totals[:clicks] += actions[:link_click].to_f
        totals[:messages] += actions[:mensagens].to_f
        totals[:leads] += actions[:leads_ads].to_f
        totals[:purchases] += actions[:compras].to_f
      end

      totals[:cpm] = safe_div(totals[:spent], totals[:impressions], 1000)
      totals[:cpc] = safe_div(totals[:spent], totals[:clicks])
      totals[:cost_per_message] = safe_div(totals[:spent], totals[:messages])
      totals[:cost_per_lead] = safe_div(totals[:spent], totals[:leads])
      totals[:cost_per_purchase] = safe_div(totals[:spent], totals[:purchases])
      totals[:frequency] = safe_div(totals[:impressions], totals[:reach])
      totals[:ctr] = safe_div(totals[:clicks], totals[:impressions])
      totals
    end

    # Mesma proteção que safeDiv faz em JS: divisão por zero é 0, não
    # Infinity/NaN (Prawn não tem glifo pra "∞" nas fontes padrão, viraria
    # lixo na página igual já aconteceu uma vez no PDF do navegador).
    def safe_div(a, b, factor = 1)
      return 0.0 if b.to_f.zero?

      v = (a.to_f / b.to_f) * factor
      v.finite? ? v : 0.0
    end

    # Totais por dia (date_start da linha) — devolve a média das métricas
    # diárias (não a métrica derivada da média), igual averageByDay em JS.
    def average_by_day(rows)
      by_day = rows.group_by { |r| r['date_start'] }
      return { avg: {}, day_count: 0, per_day: [] } if by_day.empty?

      per_day_metrics = by_day.sort.map { |date, day_rows| [date, calc_metrics(day_rows)] }
      keys = per_day_metrics.first.last.keys
      avg = keys.each_with_object({}) { |k, h| h[k] = per_day_metrics.sum { |_, m| m[k] } / per_day_metrics.size }
      { avg: avg, day_count: by_day.size, per_day: per_day_metrics }
    end

    def group_by_objective(rows)
      by_obj = rows.group_by { |r| r['objective'].presence || 'Não especificado' }
      by_obj.keys.sort.map { |name| { name: name, metrics: calc_metrics(by_obj[name]) } }
    end
  end
end
