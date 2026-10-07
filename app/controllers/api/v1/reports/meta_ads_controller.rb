# Serve o dashboard "Meta Ads" (Relatórios) chamando a Graph API ao vivo a
# cada request — igual o workflow n8n "Relatorio meta webhook" fazia — só
# que direto do backend, sem n8n. Ver Meta::AdsInsightsService.
#
# A transformação das linhas (custo por mensagem/lead calculado a partir de
# `actions`, formato em português) fica em MetaInsightsRowSerializer, extraída
# daqui para que a rota pública do link compartilhado use exatamente o mesmo
# formato — o cliente não pode ver números diferentes dos do dono da conta.
class Api::V1::Reports::MetaAdsController < Api::V1::BaseController
  # `insights` pode precisar de várias páginas da Graph API (ex.: posicionamento
  # de um mês inteiro) e `business_managers` já estourou o timeout padrão em dias
  # de servidor lento — ver incidente de 2026-10-07. O timeout padrão do
  # rack-timeout (15s) é curto demais só pra essas duas; o resto do sistema
  # continua em 15s. Setar `env['rack-timeout.timeout']` cedo no ciclo da
  # request (before_action) é o jeito suportado de sobrescrever por request.
  before_action :extend_timeout_for_meta_api, only: %i[insights business_managers]

  def insights
    conteudo = params[:conteudo].presence || 'geral'
    result = Meta::AdsInsightsService.new.campaign_insights(
      ad_account_id: params.require(:ad_account_id),
      conteudo: conteudo,
      date_start: params.require(:date_start),
      date_stop: params.require(:date_stop)
    )

    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: Array(result.data).map { |row| MetaInsightsRowSerializer.serialize(row, conteudo) }
  end

  def campaigns
    result = Meta::AdsInsightsService.new.campaigns(ad_account_id: params.require(:ad_account_id))
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: result.data
  end

  # Lista leve de contas (sem insights) pra popular o seletor no relatório —
  # substitui o campo de digitar o ID da conta manualmente. business_id
  # opcional escopa às contas de uma Business Manager específica.
  def accounts
    result = Meta::AdsInsightsService.new.ad_accounts(business_id: params[:business_id])
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: Array(result.data).map { |a| { id: a['account_id'] || a['id'].to_s.delete_prefix('act_'), name: a['name'] } }
  end

  # Lista as Business Managers pro seletor "BM" acima do seletor de conta.
  def business_managers
    result = Meta::AdsInsightsService.new.business_managers
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: result.data
  end

  private

  def extend_timeout_for_meta_api
    request.env['rack-timeout.timeout'] = 45
  end
end
