# frozen_string_literal: true

require 'rails_helper'

# A API que o relatório HTML público consome. O ponto sensível dela é o
# escopo: quem tem o link pode trocar `ad_account_id` na URL pelo devtools e
# tentar ler a performance de uma conta que o dono NÃO marcou. Estes testes
# existem para travar esse comportamento.
RSpec.describe 'API pública do relatório', type: :request do
  let(:allowed_account) { '1105931875432041' }
  let(:other_account) { '9998887776665555' }

  # Atalho para o Struct de resultado do serviço.
  def result(data)
    Meta::AdsInsightsService::Result.new(success: true, data: data)
  end

  let(:link) do
    ReportSnapshot.create!(
      title: 'Cliente Teste',
      report_type: ReportSnapshot::ADS_REPORTS,
      expires_at: 7.days.from_now,
      data: { 'ad_account_ids' => [allowed_account], 'include_google_ads' => false, 'include_ga4' => false }
    )
  end

  # Stub que responde como a Graph API responderia: o token da empresa enxerga
  # TODAS as contas, e é por isso que o filtro precisa existir no servidor.
  let(:meta_service) do
    instance_double(
      Meta::AdsInsightsService,
      ad_accounts: result([
        { 'id' => "act_#{allowed_account}", 'account_id' => allowed_account, 'name' => 'Conta Autorizada' },
        { 'id' => "act_#{other_account}", 'account_id' => other_account, 'name' => 'Conta de Outro Cliente' }
      ]),
      business_managers: result([
        { 'id' => 'bm_do_cliente', 'name' => 'BM do Cliente' },
        { 'id' => 'bm_de_outro', 'name' => 'BM de Outro Cliente' }
      ]),
      campaign_insights: result([
        { 'campaign_name' => 'Vendas', 'spend' => '100.50', 'impressions' => '1000',
          'clicks' => '10', 'actions' => [{ 'action_type' => 'link_click', 'value' => '7' }] }
      ])
    )
  end

  before do
    allow(Meta::AdsInsightsService).to receive(:new).and_return(meta_service)
  end

  def auth(token = link.token)
    { 'api_access_token' => token }
  end

  describe 'GET /public/api/v1/reports/meta_ads/insights' do
    it 'devolve os dados de uma conta marcada no link' do
      get '/public/api/v1/reports/meta_ads/insights',
          params: { ad_account_id: allowed_account, date_start: '2026-09-01', date_stop: '2026-09-30' },
          headers: auth

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(body).first).to include('campanha' => 'Vendas')
    end

    # O teste que realmente importa: o link NÃO é um crachá geral.
    it 'recusa uma conta que o link não marca, sem chamar a Meta' do
      expect(meta_service).not_to receive(:campaign_insights)

      get '/public/api/v1/reports/meta_ads/insights',
          params: { ad_account_id: other_account, date_start: '2026-09-01', date_stop: '2026-09-30' },
          headers: auth

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(body)['error']).to include('não autorizada')
    end

    it 'recusa quando não há token nenhum' do
      get '/public/api/v1/reports/meta_ads/insights',
          params: { ad_account_id: allowed_account, date_start: '2026-09-01', date_stop: '2026-09-30' }

      expect(response).to have_http_status(:gone)
    end

    it 'recusa token revogado' do
      link.revoke!

      get '/public/api/v1/reports/meta_ads/insights',
          params: { ad_account_id: allowed_account, date_start: '2026-09-01', date_stop: '2026-09-30' },
          headers: auth

      expect(response).to have_http_status(:gone)
    end

    it 'recusa token expirado' do
      link.update_column(:expires_at, 1.hour.ago)

      get '/public/api/v1/reports/meta_ads/insights',
          params: { ad_account_id: allowed_account, date_start: '2026-09-01', date_stop: '2026-09-30' },
          headers: auth

      expect(response).to have_http_status(:gone)
    end
  end

  describe 'GET /public/api/v1/reports/meta_ads/accounts' do
    it 'lista só as contas do link (o nome das outras vazaria)' do
      get '/public/api/v1/reports/meta_ads/accounts', headers: auth

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(body)).to eq([{ 'id' => allowed_account, 'name' => 'Conta Autorizada' }])
    end
  end

  describe 'GET /public/api/v1/reports/meta_ads/business_managers' do
    it 'lista só as BMs que têm conta autorizada' do
      allow(meta_service).to receive(:ad_accounts).with(business_id: 'bm_do_cliente')
        .and_return(result([{ 'id' => "act_#{allowed_account}", 'account_id' => allowed_account }]))
      allow(meta_service).to receive(:ad_accounts).with(business_id: 'bm_de_outro')
        .and_return(result([{ 'id' => "act_#{other_account}", 'account_id' => other_account }]))

      get '/public/api/v1/reports/meta_ads/business_managers', headers: auth

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(body)).to eq([{ 'id' => 'bm_do_cliente', 'name' => 'BM do Cliente' }])
    end
  end

  describe 'Google Ads e GA4' do
    it 'devolve 404 quando o link não inclui Google Ads' do
      get '/public/api/v1/reports/google_ads/insights',
          params: { date_start: '2026-09-01', date_stop: '2026-09-30' }, headers: auth

      expect(response).to have_http_status(:not_found)
    end

    it 'devolve 404 quando o link não inclui GA4' do
      get '/public/api/v1/reports/analytics/properties', headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'Leads (WhatsApp)' do
    it 'não existe rota pública de leitura nem de escrita' do
      get '/public/api/v1/reports/whatsapp_ad_leads', headers: auth
      expect(response).to have_http_status(:not_found)

      patch '/public/api/v1/reports/whatsapp_ad_leads/1', headers: auth
      expect(response).to have_http_status(:not_found)
    end
  end
end