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
    when 'listar_paginas'
      respond(service.pages_for_business(business_id: params.require(:id_bm)))
    when 'listar_formularios_lead'
      respond(service.leadgen_forms(page_id: params.require(:id_pagina)))
    when 'detalhe_formulario_lead'
      respond(service.leadgen_form_detail(page_id: params.require(:id_pagina), form_id: params.require(:id_formulario)))
    when 'atualizar_status_formulario_lead'
      respond(service.update_leadgen_form_status(
        page_id: params.require(:id_pagina),
        form_id: params.require(:id_formulario),
        status: params.require(:status)
      ))
    when 'criar_formulario_lead'
      respond(service.create_leadgen_form(**leadgen_form_params))
    when 'duplicar_formulario_lead'
      overrides = params[:overrides].is_a?(ActionController::Parameters) ? params[:overrides].to_unsafe_h.symbolize_keys : {}
      overrides[:questions] = parse_json_array(overrides[:questions]) if overrides[:questions].present?
      respond(service.duplicate_leadgen_form(
        source_page_id: params.require(:id_pagina_origem),
        form_id: params.require(:id_formulario),
        target_page_id: params.require(:id_pagina_destino),
        overrides: overrides
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
    when 'buscar_direcionamento'
      respond(service.search_targeting(query: params.require(:q), category: params.require(:categoria)))
    when 'sugestoes_direcionamento'
      respond(service.targeting_suggestions(interest_names: parse_json_array(params[:interesses])))
    when 'estimar_alcance'
      respond(service.reach_estimate(
        ad_account_id: params.require(:id_conta_anuncio),
        targeting: parse_json_object(params[:targeting])
      ))
    when 'criar_publico_salvo'
      respond(service.create_saved_audience(
        ad_account_id: params.require(:id_conta_anuncio),
        name: params.require(:name),
        targeting: parse_json_object(params[:targeting])
      ))
    # --- Listas de direcionamento (locais, não são objeto da Graph API) ---
    when 'listar_listas_direcionamento'
      render json: TargetingList.alphabetical.as_json(only: %i[id name items])
    when 'criar_lista_direcionamento'
      lista = TargetingList.new(name: params.require(:name), items: parse_json_array(params[:items]))
      if lista.save
        render json: lista.as_json(only: %i[id name items])
      else
        error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, lista.errors.full_messages.to_sentence, status: :unprocessable_entity)
      end
    when 'atualizar_lista_direcionamento'
      lista = TargetingList.find(params.require(:id))
      lista.name = params[:name] if params[:name].present?
      lista.items = parse_json_array(params[:items]) if params[:items].present?
      if lista.save
        render json: lista.as_json(only: %i[id name items])
      else
        error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, lista.errors.full_messages.to_sentence, status: :unprocessable_entity)
      end
    when 'excluir_lista_direcionamento'
      TargetingList.find(params.require(:id)).destroy
      render json: { success: true }
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

  # Usado tanto pra `questions` (array de {type} ou {type, key, label,
  # options} pra CUSTOM) quanto pra `greeting_content`/`interesses` — todos
  # chegam do front como JSON de um array, mesma forma que a Graph API
  # espera, só precisa desserializar antes de repassar pro service.
  def parse_json_array(raw)
    return [] if raw.blank?
    return raw if raw.is_a?(Array)

    parsed = JSON.parse(raw)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end

  # `targeting` chega do front como o objeto flexible_spec/exclusions/
  # geo_locations/age_min/age_max/genders inteiro, em JSON — ao contrário de
  # `edicao` (que é montado por partes e concatenado sem chaves externas),
  # este já vem pronto pra virar Hash direto.
  def parse_json_object(raw)
    return {} if raw.blank?
    return raw.to_unsafe_h if raw.is_a?(ActionController::Parameters)
    return raw if raw.is_a?(Hash)

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def leadgen_form_params
    {
      page_id: params.require(:id_pagina),
      name: params.require(:name),
      questions: parse_json_array(params[:questions]),
      privacy_policy_url: params[:privacy_policy_url],
      privacy_policy_link_text: params[:privacy_policy_link_text],
      greeting_title: params[:greeting_title],
      greeting_content: parse_json_array(params[:greeting_content]),
      greeting_button_text: params[:greeting_button_text],
      thank_you_title: params[:thank_you_title],
      thank_you_body: params[:thank_you_body],
      thank_you_button_type: params[:thank_you_button_type],
      thank_you_button_text: params[:thank_you_button_text],
      thank_you_website_url: params[:thank_you_website_url]
    }
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
