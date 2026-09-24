# Despacha os 15 passos do "Setup de Infraestrutura Meta" (Meta::InfrastructureService)
# por `acao`, mesmo estilo do Api::V1::Reports::MetaAdsManagerController — o
# front manda { acao, ...campos } e recebe a resposta real da Graph API.
#
# Modo CLIENTE: qualquer acao pode receber `fb_user_id` (conexão criada na
# aba "Conceder Acessos") — nesse caso TODAS as chamadas usam o token
# long-lived do cliente (dono da BM) em vez do token global da
# Channel::FacebookPage, e os IDs passados (business_id, ad_account_id...)
# pertencem à BM do cliente.
class Api::V1::Reports::MetaInfrastructureController < Api::V1::BaseController
  def handle
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD,
                          'Acesso do cliente não encontrado ou expirado — refaça o login na aba "Conceder Acessos".',
                          status: :unprocessable_entity) if params[:fb_user_id].present? && client_token.blank?

    service = Meta::InfrastructureService.new(access_token: client_token)

    case params[:acao]
    when 'lista_bms'
      respond(Meta::AdsManagerService.new(access_token: client_token).business_managers)
    when 'client_login_url'
      respond(Meta::ClientAccessService.login_url(conectado_por: Current.user&.id))
    when 'client_gerar_link'
      respond(Meta::ClientAccessService.gerar_link(criado_por: Current.user&.id, nome: params[:nome]))
    when 'client_links'
      respond(Meta::ClientAccessService.links)
    when 'client_verificar_permissoes'
      respond(Meta::ClientAccessService.verificar_permissoes)
    when 'client_salvar_token'
      respond(Meta::ClientAccessService.store_token(
        fb_user_id: params.require(:fb_user_id),
        token: params.require(:token),
        conectado_por: Current.user&.id
      ))
    when 'client_conexoes'
      respond(Meta::ClientAccessService.conexoes)
    when 'client_desconectar'
      respond(Meta::ClientAccessService.desconectar(params.require(:fb_user_id)))
    when 'client_lista_paginas'
      respond(service.list_pages(business_id: params[:business_id]))
    when 'client_lista_instagram'
      respond(service.list_instagram_accounts(business_id: params.require(:business_id)))
    when 'client_lista_usuarios'
      respond(list_client_users(service))
    when 'client_convidar_usuario'
      respond(invite_client_user(service))
    when 'client_remover_usuario'
      respond(service.remove_business_user(
        business_id: params.require(:business_id),
        user_id: params.require(:user_id)
      ))
    when 'conceder_acesso_parceiro_bm'
      respond(service.grant_bm_partner_access(
        business_id: params.require(:business_id),
        partner_business_id: params.require(:partner_business_id)
      ))
    when 'lista_contas_anuncio'
      respond(service.list_ad_accounts(business_id: params.require(:business_id)))
    when 'lista_datasets'
      respond(service.list_datasets(business_id: params.require(:business_id)))
    when 'criar_conta_anuncio'
      respond(service.create_ad_account(
        business_id: params.require(:business_id),
        name: params.require(:name),
        currency: params.require(:currency),
        timezone_id: params[:timezone_id].presence || '1'
      ))
    when 'criar_dataset'
      respond(service.create_dataset(business_id: params.require(:business_id), name: params.require(:name)))
    when 'configurar_dataset'
      respond(service.configure_dataset(dataset_id: params.require(:dataset_id)))
    when 'vincular_dataset_conta'
      respond(service.link_dataset_to_account(
        dataset_id: params.require(:dataset_id),
        ad_account_id: params.require(:ad_account_id),
        business_id: params.require(:business_id)
      ))
    when 'associar_dominio'
      respond(service.associate_domain(business_id: params.require(:business_id), domain: params.require(:domain)))
    when 'conectar_instagram_pagina'
      respond(service.connect_instagram_to_page(
        page_id: params.require(:page_id),
        instagram_account_id: params.require(:instagram_account_id)
      ))
    when 'vincular_pagina_conta'
      respond(service.link_page_to_ad_account(
        business_id: params.require(:business_id),
        page_id: params.require(:page_id),
        ad_account_id: params.require(:ad_account_id)
      ))
    when 'vincular_whatsapp_conta'
      respond(service.link_whatsapp_to_ad_account(
        ad_account_id: params.require(:ad_account_id),
        waba_id: params.require(:waba_id),
        page_id: params.require(:page_id),
        phone_number_id: params.require(:phone_number_id)
      ))
    when 'criar_pasta_criativos'
      respond(service.create_creative_folder(ad_account_id: params.require(:ad_account_id), name: params.require(:name)))
    when 'salvar_nomenclaturas'
      respond(service.save_naming_conventions(
        campaign: params[:campaign], adset: params[:adset], ad: params[:ad], utm: params[:utm]
      ))
    when 'inscrever_webhook_leads'
      respond(service.subscribe_leads_webhook(page_id: params.require(:page_id)))
    when 'registrar_numero_whatsapp'
      respond(service.register_whatsapp_number(phone_number_id: params.require(:phone_number_id), pin: params[:pin]))
    when 'checar_qualidade_eventos'
      respond(service.check_event_quality(dataset_id: params.require(:dataset_id)))
    when 'conceder_acesso_parceiro'
      respond(service.grant_partner_access(
        ad_account_id: params.require(:ad_account_id),
        business_id: params.require(:business_id),
        partner_business_id: params.require(:partner_business_id)
      ))
    when 'aceitar_termos_lead_ads'
      respond(service.accept_lead_ads_tos(page_id: params.require(:page_id), business_id: params.require(:business_id)))
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, "Ação desconhecida: #{params[:acao]}", status: :unprocessable_entity)
    end
  end

  private

  # Token long-lived do CLIENTE (aba "Conceder Acessos") quando a chamada
  # veio com fb_user_id; nil = comportamento antigo (token global da página).
  def client_token
    @client_token ||= Meta::ClientAccessService.token_para(params[:fb_user_id]) if params[:fb_user_id].present?
  end

  def list_client_users(service)
    usuarios = service.list_business_users(business_id: params.require(:business_id))
    return usuarios unless usuarios.success

    pendentes = service.list_pending_users(business_id: params.require(:business_id))
    usuarios.data[0]['convites_pendentes'] = pendentes.success ? pendentes.data[0]['convites_pendentes'] : []
    usuarios
  end

  def invite_client_user(service)
    role = params.require(:role)
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Role deve ser ADMIN ou EMPLOYEE.', status: :unprocessable_entity) unless %w[ADMIN EMPLOYEE].include?(role)

    service.invite_business_user(business_id: params.require(:business_id), email: params.require(:email), role: role)
  end

  def respond(result)
    if result.success
      render json: result.data
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
    end
  end
end
