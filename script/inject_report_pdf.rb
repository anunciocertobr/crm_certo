# Insere o módulo de PDF (public/report-pdf.v1.js) no HTML do relatório.
#
# O HTML do item `mtlsot4v-cf6f9s` de `dashboard-menu-items` é a única fonte
# que serve os DOIS pontos de entrada: a página pública (Public::ReportHtml
# renderiza a partir daqui) e a tela interna (que baixa esse payload da API e
# guarda no localStorage do navegador). Por isso a tag vai no próprio HTML em
# vez de ser injetada só pelo Public::ReportHtml.
#
# `defer` é obrigatório: o script principal do relatório é um <script> inline
# clássico, e suas declarações `const` (metaAdsState, META_METRIC_CONFIG,
# renderMetaAds...) só existem para os scripts clássicos seguintes se ele rodar
# depois. Com defer, este arquivo é executado já com todas elas definidas.
#
# Idempotente: o marcador abaixo faz o script abortar se a tag já estiver lá.
# Rodar de novo não duplica nada.
#
# Uso (no container do backend):
#   DRY=1 bundle exec rails runner script/inject_report_pdf.rb   # só mostra
#   bundle exec rails runner script/inject_report_pdf.rb           # aplica
module ReportPdfInjector
  SCOPE = 'dashboard-menu-items'
  ITEM_ID = 'mtlsot4v-cf6f9s'
  MARKER = '<!-- evo:report-pdf -->'
  ASSET = 'https://crmcerto.anunciocertobr.com.br/report-pdf.v1.js'
  TAG = "#{MARKER}\n<script src=\"#{ASSET}\" defer></script>\n#{MARKER}"

  module_function

  def run(dry: ENV['DRY'] == '1')
    config = MenuConfig.find_by(scope: SCOPE)
    abort("MenuConfig scope=#{SCOPE} não encontrado") if config.nil?

    item = config.payload['items'].find { |i| i['id'] == ITEM_ID }
    abort("item #{ITEM_ID} não encontrado no payload") if item.nil?

    html = item['html'].to_s
    abort('html vazio no payload') if html.empty?

    puts "html atual: #{html.bytesize} bytes, #{html.scan(/<canvas/).size} canvas"
    puts "head: #{html.scan(/<\/head>/).size} ocorrência(s)"
    puts "canvas alvo presente: #{html.include?('id=\"meta-chart-daily\"')}"

    if html.include?(MARKER)
      puts "JÁ APLICADO — nada a fazer (marcador presente)."
      return
    end

    unless html.include?('</head>')
      abort('não achei </head> no HTML; refusing to guess where to insert')
    end

    updated = html.sub('</head>', "#{TAG}</head>")
    abort('substituição não mudou nada — abortando') if updated == html

    count = updated.scan(ASSET).size
    abort("esperava 1 ocorrência do asset, achei #{count} — abortando") unless count == 1

    if dry
      puts 'DRY: Nada foi salvo. Rodo sem DRY=1 para aplicar.'
      return
    end

    backup = "/root/menuconfig_relatorio_backup_#{Time.now.strftime('%Y%m%d-%H%M%S')}.html"
    File.write(backup, html)
    puts "backup do html anterior: #{backup}"

    item['html'] = updated
    config.payload['items'] = config.payload['items'].map { |i| i['id'] == ITEM_ID ? item : i }
    config.save!

    # Relê do banco: confiar no return do save não prova nada.
    reread = MenuConfig.find_by(scope: SCOPE).payload['items'].find { |i| i['id'] == ITEM_ID }['html'].to_s
    abort('FALHA: o marcador não apareceu no banco após salvar') unless reread.include?(MARKER)
    abort('FALHA: o asset não apareceu no banco após salvar') unless reread.scan(ASSET).size == 1
    abort('FALHA: o tamanho não bate') unless reread.bytesize == updated.bytesize

    puts "OK: #{html.bytesize} -> #{reread.bytesize} bytes, asset presente, verificado relendo do banco."
  end
end

ReportPdfInjector.run