# Gera o PDF do relatório Meta Ads no SERVIDOR (Prawn, sem navegador) —
# usado pelo envio agendado ("Programar", ver ScheduledActions::
# ExecutorService#execute_send_report_pdf). Paralelo ao "Baixar PDF"/
# "Enviar" do modal (public/report-pdf.v2.js), que roda 100% no navegador
# com jsPDF; aqui não tem DOM/Chart.js disponíveis, por isso os gráficos
# são redesenhados com Reports::PrawnChartRenderer a partir dos mesmos
# dados agregados (Reports::MetaAdsAggregationService).
#
# FASE A (este arquivo, por enquanto): cards de KPI (total + média por
# dia), gráfico de barra "Gasto/Leads por dia", pizza "Investimento por
# Objetivo", tabela "Por Resultado". Os outros 6 gráficos do relatório
# completo (Top 5, Hora, Demográfico, Plataforma, Posicionamento,
# Dispositivo, Região) entram numa Fase B — todos usam breakdowns que
# Meta::AdsInsightsService já suporta (hora/idade_genero/regiao/
# posicionamento), só falta a montagem aqui.
module Reports
  class MetaAdsPdfService
    Result = Struct.new(:success, :data, :error, keyword_init: true)

    METRIC_LABELS = {
      spent: 'Gasto', impressions: 'Impressões', reach: 'Alcance', clicks: 'Cliques',
      messages: 'Mensagens', leads: 'Leads', purchases: 'Compras',
      cpm: 'CPM', cpc: 'CPC', cost_per_message: 'Custo p/ Mensagem',
      cost_per_lead: 'Custo p/ Lead', cost_per_purchase: 'Custo p/ Compra',
      frequency: 'Frequência', ctr: 'CTR'
    }.freeze
    CURRENCY_METRICS = %i[spent cpm cpc cost_per_message cost_per_lead cost_per_purchase].freeze
    PERCENTAGE_METRICS = %i[ctr].freeze
    RATIO_METRICS = %i[frequency].freeze
    DEFAULT_METRICS = %i[spent impressions clicks messages leads].freeze

    # payload['metrics_selection']['metrics'] vem do checkbox do modal
    # (report-pdf.v3.js), cujas chaves são as de META_METRIC_CONFIG — a
    # maioria já bate 1:1 com os símbolos Ruby (to_sym direto), menos as 3
    # métricas derivadas "custo por X", que no JS são camelCase
    # (costPerLead) e aqui são snake_case (cost_per_lead, convenção Ruby).
    JS_METRIC_KEYS = {
      'costPerMessage' => :cost_per_message,
      'costPerLead' => :cost_per_lead,
      'costPerPurchase' => :cost_per_purchase
    }.freeze

    def initialize(ad_account_id:, date_start:, date_stop:, metrics_selection: {})
      @ad_account_id = ad_account_id
      @date_start = date_start
      @date_stop = date_stop
      @sel = metrics_selection || {}
    end

    def call
      result = Meta::AdsInsightsService.new.campaign_insights(
        ad_account_id: @ad_account_id, conteudo: 'geral', date_start: @date_start, date_stop: @date_stop
      )
      return Result.new(success: false, error: result.error) unless result.success

      rows = result.data
      pdf_bytes = build_pdf(rows)
      Result.new(success: true, data: pdf_bytes)
    rescue StandardError => e
      Rails.logger.error("[Reports::MetaAdsPdfService] #{e.class}: #{e.message}")
      Result.new(success: false, error: e.message)
    end

    private

    def table_metrics
      raw = Array(@sel['metrics'] || @sel[:metrics])
      keys = raw.filter_map { |k| JS_METRIC_KEYS[k.to_s] || k.to_s.to_sym }
      keys &= METRIC_LABELS.keys
      keys.empty? ? DEFAULT_METRICS : keys
    end

    def want?(key, default)
      v = @sel[key.to_s]
      v.nil? ? default : !!v
    end

    def build_pdf(rows)
      totals = MetaAdsAggregationService.calc_metrics(rows)
      daily = MetaAdsAggregationService.average_by_day(rows)
      by_objective = MetaAdsAggregationService.group_by_objective(rows)

      Prawn::Document.new(page_size: 'A4', margin: 28) do |pdf|
        render_header(pdf)
        render_kpi_cards(pdf, totals, 'Total do período') if want?('want_totals', true)
        render_kpi_cards(pdf, daily[:avg], "Média por dia (#{daily[:day_count]} dias)") if want?('want_average', true) && daily[:day_count].positive?
        render_daily_chart(pdf, daily[:per_day]) if daily[:per_day].any?
        render_objective_chart(pdf, by_objective) if want?('want_objective', false) && by_objective.any?
        render_results_table(pdf, totals)
      end.render
    end

    def render_header(pdf)
      pdf.fill_color('38bdf8')
      pdf.text 'Relatório Meta Ads', size: 16, style: :bold
      pdf.fill_color('64748b')
      pdf.text "#{@date_start} a #{@date_stop} · Conta #{@ad_account_id}", size: 9
      pdf.fill_color('000000')
      pdf.move_down(10)
      pdf.stroke_color('e2e8f0')
      pdf.stroke_horizontal_rule
      pdf.stroke_color('000000')
      pdf.move_down(10)
    end

    def render_kpi_cards(pdf, metrics, title)
      pdf.text title, size: 11, style: :bold
      pdf.move_down(4)
      rows = table_metrics.each_slice(3).map do |slice|
        slice.map { |k| "#{METRIC_LABELS[k]}\n#{format_value(k, metrics[k])}" }
      end
      rows.each { |r| r.concat(Array.new(3 - r.size, '')) }
      pdf.table(rows, width: pdf.bounds.width, cell_style: { size: 9, padding: 8, border_color: 'e2e8f0' }) do |t|
        t.cells.borders = [:bottom]
      end
      pdf.move_down(14)
    end

    def render_daily_chart(pdf, per_day)
      pdf.text 'Análise Diária', size: 11, style: :bold
      pdf.move_down(6)
      labels = per_day.map { |date, _| Date.parse(date).strftime('%d/%m') }
      series = [{ label: 'Gasto (R$)', data: per_day.map { |_, m| m[:spent] } }]
      series << { label: 'Leads', data: per_day.map { |_, m| m[:leads] } } if per_day.any? { |_, m| m[:leads].positive? }
      PrawnChartRenderer.draw_bar_chart(pdf, labels: labels, series: series, value_formatter: ->(v) { v.round(0).to_s })
      pdf.move_down(8)
    end

    def render_objective_chart(pdf, by_objective)
      pdf.text 'Investimento por Objetivo', size: 11, style: :bold
      pdf.move_down(6)
      slices = by_objective.map { |o| { label: o[:name], value: o[:metrics][:spent] } }
      PrawnChartRenderer.draw_pie_chart(pdf, slices: slices, value_formatter: ->(v) { format_currency(v) })
      pdf.move_down(8)
    end

    def render_results_table(pdf, totals)
      pdf.text 'Por Resultado', size: 11, style: :bold
      pdf.move_down(4)
      rows = [['Métrica', 'Valor']] + table_metrics.map { |k| [METRIC_LABELS[k], format_value(k, totals[k])] }
      pdf.table(rows, width: pdf.bounds.width, cell_style: { size: 9, padding: 6, border_color: 'e2e8f0' }) do |t|
        t.row(0).background_color = 'f1f5f9'
        t.row(0).font_style = :bold
      end
      pdf.move_down(10)
    end

    def format_value(key, value)
      value ||= 0
      return '—' if CURRENCY_METRICS.include?(key) && value.zero? && key != :spent
      return format_currency(value) if CURRENCY_METRICS.include?(key)
      return "#{(value * 100).round(2)}%" if PERCENTAGE_METRICS.include?(key)
      return value.round(2).to_s if RATIO_METRICS.include?(key)

      value.round.to_s
    end

    def format_currency(value)
      "R$ #{format('%.2f', value.to_f).tr('.', ',')}"
    end
  end
end
