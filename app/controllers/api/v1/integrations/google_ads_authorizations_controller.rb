# Passos pós-login do Google Ads. O login em si (troca do code OAuth pelos
# tokens) é feito por
# Api::V1::Integrations::GoogleWorkspaceAuthorizationsController#callback —
# Ads reaproveita a MESMA redirect_uri/callback do google_workspace, só o
# identifier no state muda (ver Integrations::App#build_google_ads_action).
# Este controller cuida só do que vem DEPOIS do login: listar as contas de
# anúncios que a conta Google conectada enxerga (accessible_customers) e
# gravar qual delas o usuário escolheu (select_customer) — só então a
# integração fica pronta pra uso em Google::AdsInsightsService/
# AdsInfrastructureService.
class Api::V1::Integrations::GoogleAdsAuthorizationsController < Api::V1::BaseController
  def accessible_customers
    result = Google::AdsInsightsService.new.accessible_customers
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    success_response(data: { customers: result.data })
  end

  def select_customer
    hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_ads')
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Google Ads não conectado.', status: :unprocessable_entity) unless hook

    customer_id = params.require(:customer_id).to_s.gsub(/\D/, '')
    login_customer_id = params[:login_customer_id].to_s.gsub(/\D/, '')

    hook.settings = (hook.settings || {}).merge(
      'customer_id' => customer_id,
      'login_customer_id' => login_customer_id.presence
    ).compact
    hook.save!

    success_response(data: { customer_id: customer_id, login_customer_id: login_customer_id.presence })
  end
end
