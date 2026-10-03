# Serve a aba "Google Ads" (Relatórios) chamando a Google Ads API ao vivo a
# cada request, igual ao workflow n8n "Google Ads Relatorio" fazia — só que
# direto do backend, sem n8n. Ver Google::AdsInsightsService.
class Api::V1::Reports::GoogleAdsController < Api::V1::BaseController
  def insights
    service = Google::AdsInsightsService.new
    date_start = params.require(:date_start)
    date_stop = params.require(:date_stop)

    campaigns_result = service.campaigns(date_start: date_start, date_stop: date_stop)
    return respond_error(campaigns_result) unless campaigns_result.success

    terms_impressions = service.top_search_terms(date_start: date_start, date_stop: date_stop, order_by: 'metrics.impressions')
    terms_clicks = service.top_search_terms(date_start: date_start, date_stop: date_stop, order_by: 'metrics.clicks')

    render json: GoogleAdsReportSerializer.build(
      campaign_rows: campaigns_result.data,
      terms_by_impressions: terms_impressions.success ? terms_impressions.data : [],
      terms_by_clicks: terms_clicks.success ? terms_clicks.data : []
    )
  end

  private

  def respond_error(result)
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
  end
end
