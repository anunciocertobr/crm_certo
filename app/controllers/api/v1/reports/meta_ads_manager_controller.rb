# Substitui o webhook n8n do "Painel Tráfego" (gerenciador de campanhas Meta)
# por um único endpoint que despacha por `acao`, igual o Switch do n8n —
# de propósito, pra o HTML gigante em dashboards-src/painel_trafego.html
# precisar mudar só a URL que chama (webhookUrl), não a lógica inteira de
# 6+ formulários de edição que já existiam.
#
# ATENÇÃO: `editar`/`duplicar`/`criar_campanha` escrevem em anúncios/
# campanhas reais (gasto real se o status virar ACTIVE). `criar_campanha`
# não existia no n8n de referência (branch morta) — foi implementado do
# zero em Meta::AdsManagerService#create_campaign_full a partir do payload
# que o modal "Criar Campanha" do painel_trafego.html já montava.
class Api::V1::Reports::MetaAdsManagerController < Api::V1::BaseController
  def handle
    service = Meta::AdsManagerService.new

    case params[:acao]
    when 'lista_bms'
      respond(service.business_managers)
    when 'conta_de_anuncio', 'lista_de_contas'
      respond(service.ad_accounts(
        business_id: params[:id_bm],
        date_start: params[:date_start],
        date_stop: params[:date_stop]
      ))
    when 'campanhas', 'adsets', 'ads'
      respond(service.campaigns_tree(
        ad_account_id: params.require(:id_conta_anuncio),
        date_start: params.require(:date_start),
        date_stop: params.require(:date_stop)
      ))
    when 'criativo'
      respond(service.creative_details(ad_id: params.require(:id_anuncio)))
    when 'conta_info'
      respond(service.account_info(ad_account_id: params.require(:id_conta_anuncio)))
    when 'conta_historico'
      respond(service.account_history_summary(ad_account_id: params.require(:id_conta_anuncio)))
    when 'editar'
      nivel = params.require(:nivel)
      edicao = filtered_edicao(nivel, parse_edicao(params[:edicao]))
      respond(service.update(id: params.require(:id), edicao: edicao))
    when 'duplicar'
      edicao = parse_edicao(params[:edicao])
      respond(service.duplicate_ad(id: params.require(:id), edicao: edicao))
    when 'duplicar_objetivo'
      overrides = params[:overrides].is_a?(ActionController::Parameters) ? params[:overrides].to_unsafe_h : (params[:overrides] || {})
      respond(service.duplicate_with_new_objective(
        campaign_id: params.require(:id),
        ad_account_id: params.require(:id_conta_anuncio),
        new_objective: params.require(:novo_objetivo),
        new_optimization_goal: params[:novo_optimization_goal],
        overrides: overrides
      ))
    when 'duplicar_adset_objetivo'
      overrides = params[:overrides].is_a?(ActionController::Parameters) ? params[:overrides].to_unsafe_h : (params[:overrides] || {})
      respond(service.duplicate_adset_to_campaign(
        source_adset_id: params.require(:id),
        target_campaign_id: params.require(:id_campanha_destino),
        ad_account_id: params.require(:id_conta_anuncio),
        new_optimization_goal: params[:novo_optimization_goal],
        overrides: overrides
      ))
    when 'duplicar_anuncio_objetivo'
      overrides = params[:overrides].is_a?(ActionController::Parameters) ? params[:overrides].to_unsafe_h : (params[:overrides] || {})
      respond(service.duplicate_ad_to_adset(
        source_ad_id: params.require(:id),
        target_adset_id: params.require(:id_conjunto_destino),
        ad_account_id: params.require(:id_conta_anuncio),
        overrides: overrides
      ))
    when 'criar_campanha'
      campanha = params[:campanha].is_a?(ActionController::Parameters) ? params[:campanha].to_unsafe_h : (params[:campanha] || {})
      respond(service.create_campaign_full(ad_account_id: params.require(:id_conta_anuncio), campanha: campanha))
    # --- Aba "Criação Meta" (Marketing) ---
    when 'listar_formularios_lead'
      respond(service.leadgen_forms)
    when 'criar_formulario_lead'
      respond(service.create_leadgen_form(
        name: params.require(:name),
        questions: parse_questions(params[:questions]),
        privacy_policy_url: params.require(:privacy_policy_url),
        thank_you_title: params[:thank_you_title],
        thank_you_body: params[:thank_you_body]
      ))
    when 'listar_publicos'
      respond(service.custom_audiences(ad_account_id: params.require(:id_conta_anuncio)))
    when 'listar_pixels'
      respond(service.pixels(ad_account_id: params.require(:id_conta_anuncio)))
    when 'criar_publico_site'
      respond(service.create_website_audience(
        ad_account_id: params.require(:id_conta_anuncio),
        name: params.require(:name),
        pixel_id: params.require(:pixel_id),
        retention_days: params.require(:retention_days),
        url_contains: params[:url_contains],
        description: params[:description]
      ))
    when 'criar_publico_semelhante'
      respond(service.create_lookalike_audience(
        ad_account_id: params.require(:id_conta_anuncio),
        name: params.require(:name),
        origin_audience_id: params.require(:origin_audience_id),
        country: params.require(:country),
        ratio: params.require(:ratio)
      ))
    when 'criar_publico_clientes'
      respond(service.create_customer_list_audience(
        ad_account_id: params.require(:id_conta_anuncio),
        name: params.require(:name),
        description: params[:description]
      ))
    when 'adicionar_clientes_publico'
      respond(service.add_contacts_to_audience(
        audience_id: params.require(:id_publico),
        contacts: contacts_from_ids(params[:contact_ids])
      ))
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, "Ação desconhecida: #{params[:acao]}", status: :unprocessable_entity)
    end
  end

  private

  def respond(result)
    if result.success
      render json: result.data
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
    end
  end

  # O front monta `edicao` como uma string tipo `"status":"ACTIVE"` (sem
  # chaves externas) pra concatenar no corpo JSON que ia pro n8n — mantemos
  # o mesmo formato pra não precisar tocar nos 6 formulários de edição.
  def parse_edicao(raw)
    return {} if raw.blank?

    JSON.parse("{#{raw}}")
  rescue JSON::ParserError
    Rails.logger.error "Api::V1::Reports::MetaAdsManagerController: edicao inválida: #{raw.inspect}"
    {}
  end

  def filtered_edicao(nivel, edicao)
    allowed = Meta::AdsManagerService::EDITABLE_FIELDS[nivel] || []
    edicao.slice(*allowed)
  end

  # `questions` chega do front como JSON (array de {type} ou {type, key,
  # label} pra CUSTOM) — mesma forma que a Graph API espera, só precisa
  # desserializar antes de repassar pro service.
  def parse_questions(raw)
    return [] if raw.blank?
    return raw if raw.is_a?(Array)

    parsed = JSON.parse(raw)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end

  # Busca email/telefone direto do banco a partir dos ids escolhidos na UI —
  # o front nunca precisa (re)enviar o email/telefone em claro, só os ids
  # dos contatos já visíveis pra ele.
  def contacts_from_ids(ids)
    return [] if ids.blank?

    Contact.where(id: Array(ids)).pluck(:email, :phone_number).map do |email, phone|
      { email: email, phone: phone }
    end
  end
end
