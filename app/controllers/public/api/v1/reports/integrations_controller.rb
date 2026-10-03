# frozen_string_literal: true

module Public
  module Api
    module V1
      module Reports
        # Google Ads e GA4 do link público.
        #
        # As duas integrações são de conta única (não têm lista de contas como a
        # Meta), então não há escopo por conta a aplicar: o controle é a flag do
        # link. Link criado sem a flag devolve 404, e não um relatório vazio — o
        # HTML esconde o bloco quando a chamada falha, então o cliente vê o
        # relatório sem aquele bloco em vez de zeros que parecem "não gastou".
        class IntegrationsController < BaseController
          def google_insights
            return not_enabled unless link.include_google_ads?

            service = Google::AdsInsightsService.new
            date_start = params.require(:date_start)
            date_stop = params.require(:date_stop)

            campaigns = service.campaigns(date_start: date_start, date_stop: date_stop)
            return render_meta_error(campaigns) unless campaigns.success

            terms_impressions = service.top_search_terms(date_start: date_start, date_stop: date_stop, order_by: 'metrics.impressions')
            terms_clicks = service.top_search_terms(date_start: date_start, date_stop: date_stop, order_by: 'metrics.clicks')

            render json: GoogleAdsReportSerializer.build(
              campaign_rows: campaigns.data,
              terms_by_impressions: terms_impressions.success ? terms_impressions.data : [],
              terms_by_clicks: terms_clicks.success ? terms_clicks.data : []
            )
          end

          def analytics_properties
            return not_enabled unless link.include_ga4?

            respond_analytics { |service| service.list_properties }
          end

          def analytics_overview
            return not_enabled unless link.include_ga4?

            respond_analytics { |service| service.traffic_overview(analytics_params) }
          end

          def analytics_by_channel
            return not_enabled unless link.include_ga4?

            respond_analytics { |service| service.traffic_by_channel(analytics_params) }
          end

          private

          def analytics_params
            {
              property_id: params.require(:property_id),
              date_start: params.require(:date_start),
              date_stop: params.require(:date_stop)
            }
          end

          def respond_analytics
            result = yield(Google::AnalyticsInsightsService.new)
            return render_meta_error(result) unless result.success

            render json: result.data
          end

          def not_enabled
            render json: { error: 'Este relatório não inclui esta integração.' }, status: :not_found
          end
        end
      end
    end
  end
end