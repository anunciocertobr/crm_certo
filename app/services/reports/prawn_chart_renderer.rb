# Desenho de gráficos de barra/linha/pizza em Prawn pro PDF agendado do
# relatório Meta Ads (Reports::MetaAdsPdfService) — porte pragmático (não
# pixel-perfect) das funções drawChartBlock/drawLineBlock/drawPieBlock/
# pieSlices de public/report-pdf.v2.js (evo-ai-frontend-community), já que
# o PDF agendado roda no servidor sem navegador/jsPDF. Prawn não tem API
# de gráfico pronta — mesma abordagem manual de desenho vetorial que o
# jsPDF já usava, só que com as primitivas do Prawn
# (fill_rectangle/fill_polygon/stroke) em vez de doc.rect/lines.
#
# Usuário já confirmou que aceita diferença visual leve em relação ao PDF
# baixado na hora (gerado no navegador) — o objetivo aqui é um gráfico
# limpo e correto, não réplica exata.
module Reports
  module PrawnChartRenderer
    module_function

    PALETTE = %w[38bdf8 a78bfa 34d399 fbbf24 f87171 fb923c 60a5fa e879f9].freeze
    MUTED = '94a3b8'
    GRID = '334155'

    # series: [{ label:, data: [Float, ...] }], labels: [String, ...] (mesmo
    # tamanho de cada série). value_formatter: proc(Float) -> String.
    def draw_bar_chart(pdf, labels:, series:, height: 170, value_formatter: ->(v) { v.round(1).to_s })
      return if labels.empty? || series.empty?

      chart_width = pdf.bounds.width
      top = pdf.cursor
      plot_height = height - 22 # reserva espaço pros rótulos do eixo X

      max_value = series.flat_map { |s| s[:data] }.map(&:to_f).max.to_f
      max_value = 1.0 if max_value.zero?

      group_width = chart_width / labels.size
      bar_width = (group_width * 0.72) / series.size

      draw_baseline(pdf, top, plot_height, chart_width)

      labels.each_with_index do |_label, i|
        group_x = i * group_width + group_width * 0.14
        series.each_with_index do |s, si|
          value = s[:data][i].to_f
          bar_height = max_value.zero? ? 0 : (value / max_value) * plot_height
          x = group_x + si * bar_width
          y = top
          pdf.fill_color(PALETTE[si % PALETTE.size])
          pdf.fill_rectangle([x, y], bar_width * 0.85, bar_height)
          next if value <= 0

          pdf.fill_color('1e293b')
          pdf.text_box(value_formatter.call(value), at: [x - 4, y - bar_height + 9], width: bar_width + 8, size: 5, align: :center, overflow: :shrink_to_fit)
        end
      end
      pdf.fill_color('000000')

      pdf.move_down(plot_height + 4)
      draw_x_labels(pdf, labels, group_width)
      if series.size > 1
        pdf.move_down(4)
        draw_legend(pdf, series.map { |s| s[:label] })
      end
      pdf.move_down(10)
    end

    def draw_line_chart(pdf, labels:, series:, height: 170, value_formatter: ->(v) { v.round(1).to_s })
      return if labels.empty? || series.empty?

      chart_width = pdf.bounds.width
      top = pdf.cursor
      plot_height = height - 22
      step_x = labels.size > 1 ? chart_width / (labels.size - 1) : chart_width

      max_value = series.flat_map { |s| s[:data] }.map(&:to_f).max.to_f
      max_value = 1.0 if max_value.zero?

      draw_baseline(pdf, top, plot_height, chart_width)

      series.each_with_index do |s, si|
        points = s[:data].each_with_index.map do |v, i|
          y = top - (v.to_f / max_value) * plot_height
          [i * step_x, y]
        end
        pdf.stroke_color(PALETTE[si % PALETTE.size])
        pdf.line_width(1.5)
        pdf.stroke { pdf.join_style(:round); points.each_cons(2) { |p1, p2| pdf.line(p1, p2) } }
        pdf.fill_color(PALETTE[si % PALETTE.size])
        points.each { |p| pdf.fill_circle(p, 1.3) }
      end
      pdf.fill_color('000000')
      pdf.stroke_color('000000')

      pdf.move_down(plot_height + 4)
      draw_x_labels(pdf, labels, chart_width / labels.size)
      if series.size > 1
        pdf.move_down(4)
        draw_legend(pdf, series.map { |s| s[:label] })
      end
      pdf.move_down(10)
    end

    # slices: [{ label:, value: Float }]
    def draw_pie_chart(pdf, slices:, radius: 70, value_formatter: ->(v) { v.round(1).to_s })
      slices = slices.reject { |s| s[:value].to_f <= 0 }
      return if slices.empty?

      total = slices.sum { |s| s[:value].to_f }
      return if total.zero?

      top = pdf.cursor
      cx = radius + 4
      cy = top - radius

      angle = -Math::PI / 2 # começa no topo, sentido horário
      slices.each_with_index do |s, i|
        fraction = s[:value].to_f / total
        sweep = fraction * 2 * Math::PI
        pdf.fill_color(PALETTE[i % PALETTE.size])
        draw_pie_slice(pdf, cx, cy, radius, angle, angle + sweep)
        angle += sweep
      end
      pdf.fill_color('000000')

      legend_x = cx + radius + 16
      legend_y = top
      slices.each_with_index do |s, i|
        pdf.fill_color(PALETTE[i % PALETTE.size])
        pdf.fill_rectangle([legend_x, legend_y], 7, 7)
        pdf.fill_color('1e293b')
        pct = total.zero? ? 0 : (s[:value].to_f / total * 100).round(1)
        pdf.text_box("#{s[:label]} — #{value_formatter.call(s[:value])} (#{pct}%)", at: [legend_x + 11, legend_y + 2], width: pdf.bounds.width - legend_x - 11, size: 7)
        legend_y -= 13
      end
      pdf.fill_color('000000')

      pdf.move_down(radius * 2 + 14)
    end

    # ----------------------------------------------------------- helpers

    def draw_baseline(pdf, top, plot_height, width)
      pdf.stroke_color(GRID)
      pdf.line_width(0.5)
      pdf.stroke_line([0, top - plot_height], [width, top - plot_height])
      pdf.stroke_color('000000')
    end

    def draw_x_labels(pdf, labels, slot_width)
      pdf.fill_color(MUTED)
      labels.each_with_index do |label, i|
        pdf.text_box(label.to_s, at: [i * slot_width, pdf.cursor], width: slot_width, size: 6, align: :center, overflow: :shrink_to_fit)
      end
      pdf.fill_color('000000')
      pdf.move_down(10)
    end

    def draw_legend(pdf, labels)
      x = 0
      labels.each_with_index do |label, i|
        pdf.fill_color(PALETTE[i % PALETTE.size])
        pdf.fill_rectangle([x, pdf.cursor], 6, 6)
        pdf.fill_color(MUTED)
        pdf.text_box(label.to_s, at: [x + 9, pdf.cursor + 1], width: 100, size: 6)
        x += 9 + (label.to_s.length * 3.3) + 14
      end
      pdf.fill_color('000000')
      pdf.move_down(10)
    end

    # Amostra a borda do arco em pontos e fecha o polígono no centro — Prawn
    # não tem "wedge"/"arc fill" pronto, só fill_polygon com pontos.
    def draw_pie_slice(pdf, cx, cy, radius, start_angle, end_angle, steps: 24)
      points = [[cx, cy]]
      steps.times do |i|
        a = start_angle + (end_angle - start_angle) * (i.to_f / steps)
        points << [cx + radius * Math.cos(a), cy + radius * Math.sin(a)]
      end
      points << [cx + radius * Math.cos(end_angle), cy + radius * Math.sin(end_angle)]
      pdf.fill_polygon(*points)
    end
  end
end
