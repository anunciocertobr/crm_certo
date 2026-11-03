# Serve dados do Google Meu Negócio (Business Profile) pra Relatórios —
# mesma conexão/serviço já usado pelo Gestor de Posts (ver
# Api::V1::GestorPosts::BusinessProfileController), namespace `reports`
# porque aqui o uso é métricas pro relatório, não publicação de post.
class Api::V1::Reports::BusinessProfileController < Api::V1::BaseController
  def locations
    render json: { success: true, data: service.all_locations }
  rescue ::Google::BusinessProfileService::Error => e
    render json: { success: false, errors: [e.message] }, status: :bad_gateway
  end

  def performance
    data = service.performance(
      params.require(:location_name),
      date_start: params.require(:date_start),
      date_stop: params.require(:date_stop)
    )
    render json: { success: true, data: data }
  rescue ::Google::BusinessProfileService::Error => e
    render json: { success: false, errors: [e.message] }, status: :bad_gateway
  end

  private

  def service
    @service ||= ::Google::BusinessProfileService.new
  end
end
