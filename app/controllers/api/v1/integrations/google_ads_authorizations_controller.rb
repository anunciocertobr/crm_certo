# Passos pós-login do Google Ads. O login em si (troca do code OAuth pelos
# tokens, e a decisão de criar um hook novo vs. atualizar um existente) é
# feito por
# Api::V1::Integrations::GoogleWorkspaceAuthorizationsController#callback —
# Ads reaproveita a MESMA redirect_uri/callback do google_workspace, só o
# identifier no state muda (ver Integrations::App#build_google_ads_action).
#
# google_ads permite múltiplos hooks (1 por MCC/login, identificado pelo
# reference_id) — ver config/integration/apps.yml. Este controller cuida do
# que vem DEPOIS do login:
#   - `connections`: lista TODAS as conexões já feitas, cada uma com sua
#     árvore de contas — endpoint único usado por Settings, Criação Google
#     Ads, Relatórios e o diálogo de Publicar pra montar o seletor MCC/conta.
#   - `accessible_customers`/`select_customer`: só pro caso raro de um login
#     enxergar mais de 1 MCC/conta direto — o hook fica "pendente" (sem
#     reference_id, com os candidatos salvos) até o usuário escolher qual é.
class Api::V1::Integrations::GoogleAdsAuthorizationsController < Api::V1::BaseController
  def connections
    hooks = Integrations::Hook.account_hooks.where(app_id: 'google_ads')
    success_response(data: { connections: hooks.map { |hook| serialize_connection(hook) } })
  end

  def accessible_customers
    hook = find_hook
    return hook_not_found unless hook

    success_response(data: { customers: hook.settings['pending_candidates'] || [] })
  end

  def select_customer
    hook = find_hook
    return hook_not_found unless hook

    reference_id = params.require(:reference_id).to_s.gsub(/\D/, '')
    hook.reference_id = reference_id
    hook.settings = (hook.settings || {}).except('pending_candidates')
    hook.save!

    success_response(data: { hook_id: hook.id, reference_id: reference_id })
  end

  private

  def find_hook
    Integrations::Hook.account_hooks.find_by(id: params[:hook_id], app_id: 'google_ads')
  end

  def hook_not_found
    error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Conexão do Google Ads não encontrada.', status: :unprocessable_entity)
  end

  def serialize_connection(hook)
    if hook.reference_id.blank?
      return {
        hook_id: hook.id,
        reference_id: nil,
        email: hook.settings['email'],
        pending_candidates: hook.settings['pending_candidates'] || [],
        accounts: []
      }
    end

    result = Google::AdsInsightsService.new(login_customer_id: hook.reference_id).accessible_customers
    accounts = result.success ? result.data : []
    mcc = accounts.find { |a| a[:id] == hook.reference_id }

    {
      hook_id: hook.id,
      reference_id: hook.reference_id,
      email: hook.settings['email'],
      mcc_name: mcc && mcc[:name],
      accounts: accounts,
      error: result.success ? nil : result.error
    }
  end
end
