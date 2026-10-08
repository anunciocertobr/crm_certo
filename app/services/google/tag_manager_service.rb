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

    base = workspace_base(account_id, container_id, workspace_id)

    folder_map = {}
    Array(version['folder']).each do |folder|
      result = post("#{base}/folders", sanitize_resource(folder, folder_map))
      return result unless result.success

      folder_map[folder['folderId']] = result.data['folderId']
    end

    variable_map = {}
    Array(version['variable']).each do |variable|
      result = post("#{base}/variables", sanitize_resource(variable, folder_map))
      return result unless result.success

      variable_map[variable['variableId']] = result.data['variableId']
    end

    trigger_map = {}
    Array(version['trigger']).each do |trigger|
      result = post("#{base}/triggers", sanitize_resource(trigger, folder_map))
      return result unless result.success

      trigger_map[trigger['triggerId']] = result.data['triggerId']
    end

    tags_imported = 0
    Array(version['tag']).each do |tag|
      payload = sanitize_resource(tag, folder_map)
      payload['firingTriggerId'] = remap_ids(tag['firingTriggerId'], trigger_map) if tag['firingTriggerId']
      payload['blockingTriggerId'] = remap_ids(tag['blockingTriggerId'], trigger_map) if tag['blockingTriggerId']
      result = post("#{base}/tags", payload)
      return result unless result.success

      tags_imported += 1
    end

    Result.new(success: true, data: {
                 'folders' => folder_map.size,
                 'variables' => variable_map.size,
                 'triggers' => trigger_map.size,
                 'tags' => tags_imported
               })
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
