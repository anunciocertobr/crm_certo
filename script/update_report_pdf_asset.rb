# Troca a URL do asset do módulo de PDF (report-pdf.vN.js) já injetada no
# HTML do relatório — diferente de inject_report_pdf.rb, que só serve pra
# instalação NOVA (aborta se o marcador já estiver presente). Esse aqui é
# pra quando a LÓGICA do arquivo mudou e o nome precisa mudar junto (ver
# comentário no topo de report-pdf.vN.js sobre por quê): o arquivo é servido
# com Cache-Control immutable de 1 ano, então editar o conteúdo sem trocar o
# nome não atualiza nada pra quem já carregou o relatório antes do deploy.
#
# Uso (no container do backend):
#   DRY=1 bundle exec rails runner script/update_report_pdf_asset.rb   # só mostra
#   FROM=report-pdf.v1.js TO=report-pdf.v2.js bundle exec rails runner script/update_report_pdf_asset.rb
module ReportPdfAssetUpdater
  SCOPE = 'dashboard-menu-items'
  ITEM_ID = 'mtlsot4v-cf6f9s'
  BASE_URL = 'https://crmcerto.anunciocertobr.com.br'

  module_function

  def run(dry: ENV['DRY'] == '1', from_file: ENV.fetch('FROM', 'report-pdf.v1.js'), to_file: ENV.fetch('TO', 'report-pdf.v2.js'))
    from_url = "#{BASE_URL}/#{from_file}"
    to_url = "#{BASE_URL}/#{to_file}"
    abort('FROM e TO são iguais — nada a trocar') if from_url == to_url

    config = MenuConfig.find_by(scope: SCOPE)
    abort("MenuConfig scope=#{SCOPE} não encontrado") if config.nil?

    item = config.payload['items'].find { |i| i['id'] == ITEM_ID }
    abort("item #{ITEM_ID} não encontrado no payload") if item.nil?

    html = item['html'].to_s
    abort('html vazio no payload') if html.empty?

    from_count = html.scan(from_url).size
    puts "html atual: #{html.bytesize} bytes, ocorrências de #{from_url}: #{from_count}"
    abort("esperava exatamente 1 ocorrência de #{from_url}, achei #{from_count} — abortando") unless from_count == 1
    abort("#{to_url} já está presente no html — já foi trocado?") if html.include?(to_url)

    updated = html.sub(from_url, to_url)
    abort('substituição não mudou nada — abortando') if updated == html
    abort('tamanho da troca não bate com a diferença esperada') unless (updated.bytesize - html.bytesize) == (to_url.bytesize - from_url.bytesize)

    if dry
      puts "DRY: trocaria #{from_url} -> #{to_url}. Nada foi salvo."
      return
    end

    backup = "/root/menuconfig_relatorio_backup_#{Time.now.strftime('%Y%m%d-%H%M%S')}.html"
    File.write(backup, html)
    puts "backup do html anterior: #{backup}"

    item['html'] = updated
    config.payload['items'] = config.payload['items'].map { |i| i['id'] == ITEM_ID ? item : i }
    config.save!

    reread = MenuConfig.find_by(scope: SCOPE).payload['items'].find { |i| i['id'] == ITEM_ID }['html'].to_s
    abort('FALHA: a nova URL não apareceu no banco após salvar') unless reread.include?(to_url)
    abort('FALHA: a URL antiga ainda está no banco após salvar') if reread.include?(from_url)
    abort('FALHA: o tamanho não bate') unless reread.bytesize == updated.bytesize

    puts "OK: #{from_url} -> #{to_url}. #{html.bytesize} -> #{reread.bytesize} bytes, verificado relendo do banco."
  end
end

ReportPdfAssetUpdater.run
