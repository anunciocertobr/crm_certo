# frozen_string_literal: true

require 'rails_helper'

# O relatório público NÃO é uma página reescrita: é o HTML do item
# `dashboard-menu-items` do Dashboard, com o Personal Access Token trocado pelo
# token do link. Estes testes existem porque essa troca é a superfície de risco
# da feature: um erro aqui entrega uma credencial da empresa a qualquer pessoa
# com o link.
RSpec.describe 'Relatório HTML público', type: :request do
  # PAT fictício com cara de PAT (64 hex): o teste tem que pegar a classes de
  # segredo, não o valor real.
  let(:pat) { 'e8842fb5d13bb9228e3496812509ba9dfa66fdb8324a486cff795aedb819b9ef' }

  let(:original_html) do
    <<~HTML
      <html>
      <head>
        <title>Relatórios</title>
        <link rel="stylesheet" href="https://cdn.example/x.css"
              integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=">
      </head>
      <body>
        <canvas id="grafico"></canvas>
        <script>
          const DASHBOARD_API_TOKEN = '#{pat}';
          const DASHBOARD_API_BASE = 'https://api.exemplo.com.br';
          async function chamar(url) {
            const r = await fetch(DASHBOARD_API_BASE + url, {
              headers: { 'api_access_token': DASHBOARD_API_TOKEN }
            });
            return r.json();
          }
          function renderAnalyticsPropertyOptions() { return chamar('/api/v1/x'); }
        </script>
      </body>
      </html>
    HTML
  end

  let(:menu_config) do
    MenuConfig.create!(
      scope: Public::ReportHtml::SCOPE,
      payload: {
        'items' => [
          { 'id' => 'outro-item', 'title' => 'Outro', 'html' => '<html><head></head><body>oi</body></html>' },
          { 'id' => Public::ReportHtml::ITEM_ID, 'title' => 'Relatórios', 'html' => original_html }
        ]
      }
    )
  end

  let(:link) do
    ReportSnapshot.create!(
      title: 'Cliente Teste',
      report_type: ReportSnapshot::ADS_REPORTS,
      expires_at: 7.days.from_now,
      data: {
        'ad_account_ids' => %w[1105931875432041 9998887776665555],
        'include_google_ads' => false,
        'include_ga4' => false
      }
    )
  end

  def body
    response.body
  end

  describe 'GET /public/r/:token' do
    before { menu_config }

    it 'serve o relatório sem o Personal Access Token' do
      get "/public/r/#{link.token}"

      expect(response).to have_http_status(:ok)
      expect(body).to include("const DASHBOARD_API_TOKEN = '#{link.token}'")
      expect(body).not_to include(pat)
    end

    it 'preserva o HTML original (gráficos, CDN e hash de integridade)' do
      get "/public/r/#{link.token}"

      expect(body).to include('<canvas id="grafico"></canvas>')
      expect(body).to include('integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY="')
      expect(body).to include('function renderAnalyticsPropertyOptions')
    end

    it 'manda as chamadas para as rotas públicas' do
      get "/public/r/#{link.token}"

      expect(body).to include("DASHBOARD_API_BASE + '/public' + url")
      expect(body).not_to include('DASHBOARD_API_BASE + url')
    end

    it 'pré-seleciona a primeira conta do link' do
      get "/public/r/#{link.token}"

      expect(body).to include("accountId: \"#{link.ad_account_ids.first}\"")
    end

    it 'abre em Meta Ads, não na aba de Leads que escondemos' do
      get "/public/r/#{link.token}"

      expect(body).to include("handlePageChange('meta-ads')")
    end

    it 'não pede leads e esconde a aba (nome e telefone de cliente)' do
      get "/public/r/#{link.token}"

      expect(body).to include("[data-page='leads-dashboard'] { display: none !important; }")
      expect(body).to include('/whatsapp_ad_leads')
      expect(body).to include('[]')
    end

    it 'bloqueia métodos de escrita no navegador' do
      get "/public/r/#{link.token}"

      expect(body).to include('Relatório somente leitura.')
    end

    it 'não deixa a página em cache compartilhado' do
      get "/public/r/#{link.token}"

      expect(response.headers['Cache-Control']).to include('no-store')
      expect(response.headers['Referrer-Policy']).to eq('no-referrer')
    end

    it 'lê o HTML atual do menu a cada request' do
      get "/public/r/#{link.token}"
      expect(body).to include('grafico')

      menu_config.update!(payload: { 'items' => [
        { 'id' => Public::ReportHtml::ITEM_ID, 'html' => original_html.sub('grafico', 'grafico-novo') }
      ] })

      get "/public/r/#{link.token}"
      expect(body).to include('grafico-novo')
    end

    context 'quando o link foi revogado' do
      it 'devolve 410' do
        link.revoke!
        get "/public/r/#{link.token}"

        expect(response).to have_http_status(:gone)
      end
    end

    context 'quando o link expirou' do
      it 'devolve 410' do
        link.update_column(:expires_at, 1.day.ago)
        get "/public/r/#{link.token}"

        expect(response).to have_http_status(:gone)
      end
    end

    context 'quando o token não existe' do
      it 'devolve 410 sem revelar se existe' do
        get '/public/r/token-inexistente'

        expect(response).to have_http_status(:gone)
      end
    end

    # Falha fechada: se alguém editar o HTML e a constante mudar de nome, o
    # seguro é a página não responder, não o PAT ir para o cliente.
    context 'quando o HTML muda e a constante do token some' do
      it 'não serve a página' do
        menu_config.update!(payload: { 'items' => [
          { 'id' => Public::ReportHtml::ITEM_ID,
            'html' => original_html.sub('DASHBOARD_API_TOKEN', 'OUTRO_NOME').sub(/'#{pat}'/, "'#{pat}'") }
        ] })

        get "/public/r/#{link.token}"

        expect(response).to have_http_status(:internal_server_error)
        expect(body).not_to include(pat)
      end
    end

    context 'quando o item do menu não existe' do
      it 'não serve a página' do
        menu_config.update!(payload: { 'items' => [] })
        get "/public/r/#{link.token}"

        expect(response).to have_http_status(:internal_server_error)
      end
    end
  end
end