require 'net/http'

# Google::TagManagerService - integração com a API v2 do Google Tag Manager
# (https://tagmanager.googleapis.com/tagmanager/v2/) usando o token da conta
# Google conectada (Google::WorkspaceTokenService). Cobre leitura, criação,
# edição e remoção de contêineres/tags/acionadores/variáveis/pastas,
# importação de contêiner e gerenciamento de permissões (compartilhamento).
#
# NOTA: a API do GTM não expõe criação de "contas" — isso só existe pela UI
# do próprio tagmanager.google.com (limitação do Google, não deste serviço).
class Google::TagManagerService
  BASE_URL = 'https://tagmanager.googleapis.com/tagmanager/v2'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  # --- Leitura ---------------------------------------------------------

  def accounts
    get('/accounts', 'account')
  end

  def containers(account_id)
    get("/accounts/#{account_id}/containers", 'container')
  end

  def workspace(account_id, container_id)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Nenhum workspace encontrado neste contêiner.') unless workspace_id

    base = workspace_base(account_id, container_id, workspace_id)
    tags = get("#{base}/tags", 'tag')
    triggers = get("#{base}/triggers", 'trigger')
    variables = get("#{base}/variables", 'variable')
    folders = get("#{base}/folders", 'folder')
    templates = get("#{base}/templates", 'template')

    failed = [tags, triggers, variables, folders, templates].find { |r| !r.success }
    return failed if failed

    Result.new(success: true, data: {
                 workspace_id: workspace_id,
                 tags: tags.data,
                 triggers: triggers.data,
                 variables: variables.data,
                 folders: folders.data,
                 templates: templates.data
               })
  end

  # --- Contêineres -------------------------------------------------------

  def create_container(account_id, name, usage_context)
    post("/accounts/#{account_id}/containers", { name: name, usageContext: [usage_context] })
  end

  def delete_container(account_id, container_id)
    delete("/accounts/#{account_id}/containers/#{container_id}")
  end

  # --- Recursos do workspace (tags/acionadores/variáveis/pastas) ---------
  # `resource` é um dos: tags, triggers, variables, folders

  def create_resource(account_id, container_id, resource, payload)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    post("#{workspace_base(account_id, container_id, workspace_id)}/#{resource}", payload)
  end

  def update_resource(account_id, container_id, resource, resource_id, payload)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    put("#{workspace_base(account_id, container_id, workspace_id)}/#{resource}/#{resource_id}", payload)
  end

  def delete_resource(account_id, container_id, resource, resource_id)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    delete("#{workspace_base(account_id, container_id, workspace_id)}/#{resource}/#{resource_id}")
  end

  # --- Importação de contêiner ---------------------------------------
  # A API do Tag Manager NÃO tem um endpoint que aceite de uma vez só o JSON
  # inteiro gerado por "Export Container" na UI do GTM — confirmado ao vivo
  # (POST .../workspaces/:id:import_container devolve 404, esse endpoint não
  # existe). O jeito real de importar programaticamente é recriar cada
  # recurso (pasta, variável, acionador, tag) um por um via create_resource,
  # na ordem que resolve as dependências, remapeando os ids antigos (do
  # contêiner de origem, que aparecem em `firingTriggerId`/`parentFolderId`)
  # pros ids novos que a API devolve ao criar no contêiner de destino.
  #
  # Limitação conhecida: setupTag/teardownTag (uma tag disparando outra) não
  # são remapeados, e variáveis internas do GTM (builtInVariable) não são
  # reativadas — raro o suficiente pra não bloquear o caso comum.
  IDENTITY_FIELDS = %w[accountId containerId workspaceId tagId triggerId variableId folderId fingerprint path tagManagerUrl].freeze

  def import_container(account_id, container_id, container_version_json)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    version = parse_container_version(container_version_json)
    return version unless version.is_a?(Hash)

    source_container_id = version.dig('container', 'containerId') || container_id
    base = workspace_base(account_id, container_id, workspace_id)
    recreate_resources(base, version, source_container_id, container_id)
  end

  # --- Criar contêiner a partir de um modelo pronto ----------------------
  # Cria um contêiner novo e já importa nele o mesmo conjunto de
  # tags/acionadores/variáveis/templates de um contêiner-modelo de
  # referência (web: "0 modelos GTM" / Wordpress Woocommerce GTM4; server:
  # Vmax Server, usado como referência por já ter a config padrão de
  # Facebook CAPI + TikTok Events API). IDs/tokens/URL são opcionais — o que
  # não for informado em `fields` vira o placeholder '0000000000' (ou a URL
  # de exemplo, pro campo de planilha), pra deixar óbvio que falta preencher
  # depois no próprio GTM.
  WEB_TEMPLATE = { account_id: '6264689624', container_id: '203827379' }.freeze
  SERVER_TEMPLATE = { account_id: '6005383959', container_id: '55224011' }.freeze
  DEFAULT_PLACEHOLDER = '0000000000'.freeze
  DEFAULT_SHEET_URL = 'https://script.google.com/macros/s/0000000000/exec'.freeze

  # Nome exato da variável (type 'c') no contêiner-modelo <- chave que o
  # formulário do frontend usa pra mandar o valor preenchido pelo usuário.
  WEB_ID_FIELDS = {
    'facebook_pixel_id' => '01 FACEBOOK ADS - ID do Pixel (colar ID Pixel Facebook)',
    'ga4_id' => '02 Google Analytics GA4 - ID (colar ID GA4)',
    'ua_id' => '03 Google Analytics - UA (colar ID UA)',
    'google_ads_id' => '04 Google ADS - ID do Pixel',
    'tiktok_pixel_id' => '05 ID TikTok Pixel (colar ID do TikTok)',
    'pinterest_id' => '06 ID Pinterest',
    'linkedin_id' => '07 ID Linkedin',
    'transport_url_facebook' => '06 API Transporte URL Facebook (colar URL do Servidor Facebook)',
    'transport_url_tiktok' => '06 API Transporte URL TikTok (colar URL do Servidor TikTok)',
    'google_ads_label_ver_conteudo' => 'Google ADS - Ver conteudo (código pego na campanha na parte de tag rotulo da conversão)',
    'google_ads_label_carrinho' => 'Google ADS - carrinho (código pego na campanha na parte de tag rotulo da conversão)',
    'google_ads_label_checkout' => 'Google ADS - iniciar finalização de compra (código pego na campanha na parte de tag rotulo da conversão)',
    'google_ads_label_compra' => 'Google ADS - compra (código pego na campanha na parte de tag rotulo da conversão)',
    'google_ads_label_lead' => 'Google ADS - Lead (código pego na campanha na parte de tag rotulo da conversão)'
  }.freeze

  SERVER_ID_FIELDS = {
    'facebook_pixel_id' => 'FACEBOOK PIXEL',
    'facebook_token' => 'FACEBOOK Token API',
    'tiktok_pixel_id' => '01 TikTok ID do Pixel (Colar ID do Pixel)',
    'tiktok_token' => '02 TikTok Token (Colar Token do Pixel)'
  }.freeze

  def create_container_from_template(account_id, client_name, usage_context, fields = {}, sheet_url = nil)
    is_server = usage_context == 'server'
    suffix = is_server ? 'Server' : 'Web'
    container_result = create_container(account_id, "#{client_name} (#{suffix})", is_server ? 'server' : 'web')
    return container_result unless container_result.success

    new_container_id = container_result.data['containerId']
    template_ref = is_server ? SERVER_TEMPLATE : WEB_TEMPLATE
    field_map = is_server ? SERVER_ID_FIELDS : WEB_ID_FIELDS

    source_ws = workspace(template_ref[:account_id], template_ref[:container_id])
    return source_ws unless source_ws.success

    variable_values = field_map.each_with_object({}) do |(key, variable_name), acc|
      acc[variable_name] = fields[key].presence || DEFAULT_PLACEHOLDER
    end
    field_overrides = {
      variable_values: variable_values,
      sheet_url: is_server ? nil : (sheet_url.presence || DEFAULT_SHEET_URL)
    }

    dest_workspace_id = default_workspace_id(account_id, new_container_id)
    unless dest_workspace_id
      return Result.new(success: false, error: 'Contêiner criado, mas o workspace novo não foi encontrado pra importar o modelo.')
    end

    base = workspace_base(account_id, new_container_id, dest_workspace_id)
    version = {
      'folder' => source_ws.data[:folders],
      'variable' => source_ws.data[:variables],
      'trigger' => source_ws.data[:triggers],
      'tag' => source_ws.data[:tags],
      'template' => source_ws.data[:templates]
    }

    recreate_result = recreate_resources(base, version, template_ref[:container_id], new_container_id, field_overrides)
    return recreate_result unless recreate_result.success

    Result.new(success: true, data: container_result.data.merge('import' => recreate_result.data))
  end

  # --- Permissões / compartilhamento -----------------------------------

  def account_permissions(account_id)
    get("/accounts/#{account_id}/user_permissions", 'userPermission')
  end

  def create_account_permission(account_id, email, account_permission, container_id, container_permission)
    payload = {
      accountId: account_id,
      emailAddress: email,
      accountAccess: { permission: account_permission }
    }
    if container_id.present?
      payload[:containerAccess] = [{ containerId: container_id, permission: container_permission }]
    end
    post("/accounts/#{account_id}/user_permissions", payload)
  end

  def delete_account_permission(account_id, permission_id)
    delete("/accounts/#{account_id}/user_permissions/#{permission_id}")
  end

  # --- Versões e publicação ---------------------------------------------
  # Cria uma versão a partir do workspace padrão (congela o estado atual
  # dos tags/triggers/variáveis) e, opcionalmente, publica — só depois de
  # publicar as mudanças passam a valer no site de verdade.

  def create_version(account_id, container_id, name = nil)
    workspace_id = default_workspace_id(account_id, container_id)
    return Result.new(success: false, error: 'Workspace não encontrado.') unless workspace_id

    payload = {}
    payload[:name] = name if name.present?
    post("#{workspace_base(account_id, container_id, workspace_id)}:create_version", payload)
  end

  def publish_version(account_id, container_id, container_version_id)
    post("/accounts/#{account_id}/containers/#{container_id}/versions/#{container_version_id}:publish", {})
  end

  private

  def default_workspace_id(account_id, container_id)
    result = get("/accounts/#{account_id}/containers/#{container_id}/workspaces", 'workspace')
    return nil unless result.success

    result.data.first&.dig('workspaceId')
  end

  def workspace_base(account_id, container_id, workspace_id)
    "/accounts/#{account_id}/containers/#{container_id}/workspaces/#{workspace_id}"
  end

  # Aceita tanto o arquivo de export completo (com exportFormatVersion/
  # exportTime/containerVersion) quanto só o objeto containerVersion direto.
  def parse_container_version(container_version_json)
    parsed = JSON.parse(container_version_json)
    parsed['containerVersion'] || parsed
  rescue JSON::ParserError
    Result.new(success: false, error: 'JSON inválido — exporte o contêiner de novo pelo GTM e tente outra vez.')
  end

  # Remove os ids do contêiner de ORIGEM (a API gera novos ao criar no
  # destino) e remapeia parentFolderId pro id da pasta já recriada aqui.
  def sanitize_resource(resource, folder_map)
    payload = resource.except(*IDENTITY_FIELDS)
    if resource['parentFolderId'] && folder_map[resource['parentFolderId']]
      payload['parentFolderId'] = folder_map[resource['parentFolderId']]
    end
    payload
  end

  def remap_ids(ids, map)
    Array(ids).map { |id| map[id] || id }
  end

  # Recria pastas/variáveis/acionadores/tags de `version` dentro do
  # workspace de destino (`base`), na ordem que resolve as dependências:
  # 1) templates customizados primeiro (tags tipo Facebook CAPI/TikTok
  #    Events API etc. são baseados neles — sem recriar o template, a tag
  #    nem consegue ser criada, já que o `type` dela referencia o id do
  #    template no contêiner de ORIGEM) — reinstala pela galleryReference
  #    quando veio da galeria (o caso comum), senão copia o templateData.
  # 2) pastas (pra resolver parentFolderId).
  # 3) variáveis, acionadores, tags — remapeando qualquer `type` cvt_* pro
  #    novo id de template e firingTriggerId/blockingTriggerId pro novo id
  #    de acionador.
  # `field_overrides` (opcional) permite sobrescrever o valor de variáveis
  # constantes (`type: 'c'`) pelo NOME e trocar a URL de tags de planilha —
  # usado por create_container_from_template pra preencher IDs/tokens/URL
  # na hora de importar, sem precisar de uma segunda rodada de updates.
  # A cota de escrita do Tag Manager é 30/min por usuário — um contêiner
  # grande (o modelo tem ~90 tags + ~90 variáveis) facilmente passa disso.
  # Pausa entre cada chamada de escrita pra não tomar 429 no meio da
  # importação (confirmado ao vivo: sem pausa, quebra sempre no mesmo
  # lugar). Por isso quem chama isto pra um contêiner grande (ver
  # create_container_from_template) roda em background job, não numa
  # requisição HTTP síncrona — a importação inteira pode levar minutos.
  RATE_LIMIT_PAUSE = 2.2

  def recreate_resources(base, version, source_container_id, dest_container_id, field_overrides = nil)
    template_map = {}
    Array(version['template']).each do |template|
      # A API exige o código-fonte (templateData) mesmo quando o template
      # veio da galeria — galleryReference sozinho não basta (confirmado ao
      # vivo: 400 "Missing section ___INFO___" mandando só a referência).
      payload = { 'name' => template['name'], 'templateData' => template['templateData'] }
      payload['galleryReference'] = template['galleryReference'] if template['galleryReference']
      result = post("#{base}/templates", payload)
      sleep(RATE_LIMIT_PAUSE)
      return result unless result.success

      old_type = "cvt_#{source_container_id}_#{template['templateId']}"
      new_type = "cvt_#{dest_container_id}_#{result.data['templateId']}"
      template_map[old_type] = new_type
    end
    remap_type = ->(type) { template_map[type] || type }

    folder_map = {}
    Array(version['folder']).each do |folder|
      result = post("#{base}/folders", sanitize_resource(folder, folder_map))
      sleep(RATE_LIMIT_PAUSE)
      return result unless result.success

      folder_map[folder['folderId']] = result.data['folderId']
    end

    variable_map = {}
    Array(version['variable']).each do |variable|
      payload = sanitize_resource(variable, folder_map)
      payload['type'] = remap_type.call(payload['type'])
      apply_field_override!(payload, field_overrides)
      result = post("#{base}/variables", payload)
      sleep(RATE_LIMIT_PAUSE)
      return result unless result.success

      variable_map[variable['variableId']] = result.data['variableId']
    end

    trigger_map = {}
    Array(version['trigger']).each do |trigger|
      payload = sanitize_resource(trigger, folder_map)
      payload['type'] = remap_type.call(payload['type'])
      result = post("#{base}/triggers", payload)
      sleep(RATE_LIMIT_PAUSE)
      return result unless result.success

      trigger_map[trigger['triggerId']] = result.data['triggerId']
    end

    tags_imported = 0
    Array(version['tag']).each do |tag|
      payload = sanitize_resource(tag, folder_map)
      payload['type'] = remap_type.call(payload['type'])
      payload['firingTriggerId'] = remap_ids(tag['firingTriggerId'], trigger_map) if tag['firingTriggerId']
      payload['blockingTriggerId'] = remap_ids(tag['blockingTriggerId'], trigger_map) if tag['blockingTriggerId']
      apply_field_override!(payload, field_overrides)
      result = post("#{base}/tags", payload)
      sleep(RATE_LIMIT_PAUSE)
      return result unless result.success

      tags_imported += 1
    end

    Result.new(success: true, data: {
                 'templates' => template_map.size,
                 'folders' => folder_map.size,
                 'variables' => variable_map.size,
                 'triggers' => trigger_map.size,
                 'tags' => tags_imported
               })
  end

  def apply_field_override!(payload, field_overrides)
    return unless field_overrides

    if payload['type'] == 'c' && field_overrides[:variable_values]&.key?(payload['name'])
      value_param = Array(payload['parameter']).find { |p| p['key'] == 'value' }
      value_param['value'] = field_overrides[:variable_values][payload['name']] if value_param
    end

    if field_overrides[:sheet_url] && payload['type'] == 'img' && payload['name'].to_s.downcase.include?('sheet')
      url_param = Array(payload['parameter']).find { |p| p['key'] == 'url' }
      if url_param
        url_param['value'] = url_param['value'].sub(%r{https://script\.google\.com/macros/s/[^/]+/exec}, field_overrides[:sheet_url])
      end
    end
  end

  def token
    @token ||= Google::WorkspaceTokenService.new.access_token
  end

  def get(path, list_key)
    response = request(:get, path)
    return response unless response.success

    parsed = JSON.parse(response.data)
    Result.new(success: true, data: Array(parsed[list_key]))
  end

  def post(path, payload, query: nil)
    full_path = query.present? ? "#{path}?#{query}" : path
    response = request(:post, full_path, payload)
    return response unless response.success

    Result.new(success: true, data: JSON.parse(response.data))
  end

  def put(path, payload)
    response = request(:put, path, payload)
    return response unless response.success

    Result.new(success: true, data: JSON.parse(response.data))
  end

  def delete(path)
    request(:delete, path)
  end

  def request(method, path, payload = nil)
    return Result.new(success: false, error: 'Conta Google não conectada.') unless token

    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = build_request(method, uri, payload)
    request['Authorization'] = "Bearer #{token}"

    response = http.request(request)
    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::TagManagerService: #{method.upcase} #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: friendly_error(response.code))
    end

    Result.new(success: true, data: response.body)
  rescue StandardError => e
    Rails.logger.error "Google::TagManagerService: #{method.upcase} #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar o Google Tag Manager.')
  end

  def build_request(method, uri, payload)
    case method
    when :get
      Net::HTTP::Get.new(uri.request_uri)
    when :post
      req = Net::HTTP::Post.new(uri.request_uri)
      apply_json_body(req, payload)
    when :put
      req = Net::HTTP::Put.new(uri.request_uri)
      apply_json_body(req, payload)
    when :delete
      Net::HTTP::Delete.new(uri.request_uri)
    end
  end

  def apply_json_body(req, payload)
    if payload.present?
      req['Content-Type'] = 'application/json'
      req.body = payload.to_json
    end
    req
  end

  def friendly_error(code)
    case code.to_s
    when '401'
      'Sessão do Google expirada. Reconecte em Configurações > Integrações.'
    when '403'
      'Sem permissão para esta ação no Google Tag Manager com esta conta Google.'
    when '404'
      'Recurso não encontrado no Google Tag Manager.'
    when '409'
      'Conflito: o recurso foi alterado por outra pessoa. Recarregue e tente novamente.'
    else
      'Falha ao consultar o Google Tag Manager.'
    end
  end
end
