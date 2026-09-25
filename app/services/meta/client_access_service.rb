require 'cgi'

# Meta::ClientAccessService - fluxo de "Conceder Acessos" (aba nova do Setup
# Marketing): o CLIENTE (dono da Business Manager) faz login com o Facebook
# num popup e o token long-lived dele fica guardado aqui, pra que o app
# possa operar a BM do cliente com o token DELE (criar conta de anúncio/
# dataset, conectar página/Instagram, definir empresa parceira, gerenciar
# acessos) — diferente do token global de Channel::FacebookPage usado no
# resto do setup.
#
# Login via FB JS SDK (e não OAuth por redirect): o dashboard vive num iframe
# com sandbox sem allow-same-origin (sem cookies). O popup abre uma rota do
# próprio CRM (/meta-client-login, domínio já autorizado no app da Meta) que
# roda o FB.login com os escopos desta aba e devolve o token pro dashboard
# via postMessage; o dashboard salva por aqui. Isso dispensa cadastrar URLs
# de redirect no painel da Meta e o mesmo login já funciona pro par de páginas.
#
# Os tokens de vários clientes convivem num ÚNICO hook account
# (app_id meta_client_access), mapados por fb_user_id dentro de
# settings['clientes'] — o modelo Integrations::Hook não tem account_id
# e valida unicidade de app_id quando o app não está registrado no
# apps.yml (de propósito, pra não poluir a tela de Integrações).
class Meta::ClientAccessService
  HOOK_APP_ID = 'meta_client_access'.freeze

  # Escopos necessários pras operações desta aba: navegar BMs/contas
  # (business_management), criar/atualizar anúncios (ads_management,
  # ads_read), páginas (pages_show_list + gerenciar metadados/engajamento
  # pra conectar Instagram e inscrever webhook de leads), leads
  # (leads_retrieval) e Instagram (instagram_basic).
  #
  # NOTA: whatsapp_business_management foi REMOVIDO do escopo de login.
  # Ele tem fluxo próprio de aprovação (WhatsApp Cloud API) e, pedido no
  # diálogo do SDK, faz o Facebook recusar a lista inteira com "este app
  # precisa de pelo menos uma supported permission". O registro de número
  # no WhatsApp usa o embedded signup (guardado nos grants do token), não
  # depende deste escopo de login.
  SCOPE = %w[
    business_management ads_management ads_read pages_show_list
    pages_manage_metadata pages_manage_engagement leads_retrieval
    instagram_basic
  ].join(',').freeze

  # As permissões do escopo acima precisam todas constar como "live" no
  # endpoint /{app_id}/permissions — confira no painel o estado real.
  PERMISSOES_REQUERIDAS = SCOPE.split(',').freeze
  API_VERSION = 'v21.0'.freeze

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  # URL do popup aberto pelo dashboard (botão "Login com Facebook"). Gera um
  # GRANT igual ao link copiável: assim o popup salva direto no endpoint
  # público /meta_client/grants (independente do postMessage, que se perde
  # por causa do allow-popups-to-escape-sandbox do ContentViewer) e o
  # dashboard pega o cliente pelo polling de client_conexoes.
  # app_id e escopos vão na query, pois são públicos do app.
  def self.login_url(conectado_por:)
    app_id = GlobalConfigService.load('FB_APP_ID', '')
    return Result.new(success: false, error: 'FB_APP_ID não configurado no GlobalConfig.') if app_id.blank?

    frontend_url = ENV['FRONTEND_URL'].presence
    return Result.new(success: false, error: 'FRONTEND_URL não configurado no ambiente.') if frontend_url.blank?

    grant = SecureRandom.hex(16)
    add_grant(grant, conectado_por, nil)

    url = "#{frontend_url.gsub(%r{/+\z}, '')}/meta-client.html" \
          "?grant=#{grant}&app_id=#{CGI.escape(app_id)}&scope=#{CGI.escape(SCOPE)}&conectado_por=#{conectado_por}"

    Result.new(success: true, data: { 'url' => url })
  end

  # Gera um link COPIÁVEL pra mandar ao cliente (WhatsApp/e-mail): o cliente
  # abre O link no navegador DELE e autoriza o próprio Facebook, sem estar
  # logado no CRM. O link carrega um segredo único (grant) mais forte que o
  # simples acesso — quem tiver o link pode autorizar; depois de usado, o
  # link expira (aplicar_grant apaga o grant).
  def self.gerar_link(criado_por:, nome: nil)
    app_id = GlobalConfigService.load('FB_APP_ID', '')
    return Result.new(success: false, error: 'FB_APP_ID não configurado no GlobalConfig.') if app_id.blank?

    frontend_url = ENV['FRONTEND_URL'].presence
    return Result.new(success: false, error: 'FRONTEND_URL não configurado no ambiente.') if frontend_url.blank?

    grant = SecureRandom.hex(16)
    add_grant(grant, criado_por, nome)

    url = "#{frontend_url.gsub(%r{/+\z}, '')}/meta-client.html" \
          "?grant=#{grant}&app_id=#{CGI.escape(app_id)}&scope=#{CGI.escape(SCOPE)}"

    Result.new(success: true, data: { 'url' => url })
  end

  # Lista os links pendentes (gerados, ainda não utilizados) pro dashboard
  # saber o que está aguardando o cliente.
  def self.links
    hook = Integrations::Hook.account_hooks.find_by(app_id: HOOK_APP_ID)
    grants = ((hook&.settings || {})['grants'] || {})

    lista = grants.map do |_grant, meta|
      { 'nome' => meta['nome'], 'criado_em' => meta['criado_em'], 'criado_por' => meta['criado_por'] }
    end

    Result.new(success: true, data: [{ 'links' => lista }])
  end

  # Endpoint PÚBLICO (sem sessão) chamado pelo popup que o cliente abriu
  # pelo link: valida o segredo do link, troca o token curto do FB.login por
  # long-lived, identifica o usuário e grava a conexão — com rastro de quem
  # gerou o link (criado_por). O link expira após o primeiro uso.
  def self.aplicar_grant(grant:, fb_user_id:, token:)
    meta = grant_para(grant)
    return Result.new(success: false, error: 'Link de acesso inválido ou já utilizado.') if meta.blank?
    return Result.new(success: false, error: 'fb_user_id não informado.') if fb_user_id.blank?
    return Result.new(success: false, error: 'access token não informado.') if token.blank?

    oauth = Koala::Facebook::OAuth.new(
      GlobalConfigService.load('FB_APP_ID', ''),
      GlobalConfigService.load('FB_APP_SECRET', '')
    )

    long_lived = exchange_for_long_lived(oauth, token)
    profile = Koala::Facebook::API.new(long_lived[:token]).get_object('me', fields: 'id,name')

    unless profile['id'].to_s == fb_user_id.to_s
      return Result.new(success: false, error: 'O usuário do token não corresponde ao informado pelo popup.')
    end

    store_connection(
      fb_user_id: profile['id'],
      nome: profile['name'],
      token: long_lived[:token],
      expires_at: long_lived[:expires_at],
      conectado_por: meta['criado_por']
    )
    delete_grant(grant)

    Result.new(success: true, data: { 'fb_user_id' => profile['id'], 'nome' => profile['name'] })
  rescue Koala::Facebook::OAuthTokenRequestError => e
    Rails.logger.error "Meta::ClientAccessService: OAuth falhou: #{e.message}"
    Result.new(success: false, error: "Login do Facebook falhou: #{e.message}")
  rescue StandardError => e
    Rails.logger.error "Meta::ClientAccessService: aplicar_grant #{e.class} #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao salvar o acesso do cliente.')
  end

  # Chamado pelo dashboard (autenticado na API) logo depois que o popup do
  # SDK devolveu o token via postMessage. O token do FB.login é curto — troca
  # por long-lived (~60 dias via fb_exchange_token), identifica o usuário do
  # Facebook e grava/atualiza a conexão dele no hook.
  def self.store_token(fb_user_id:, token:, conectado_por:)
    return Result.new(success: false, error: 'fb_user_id não informado.') if fb_user_id.blank?
    return Result.new(success: false, error: 'access token não informado.') if token.blank?

    oauth = Koala::Facebook::OAuth.new(
      GlobalConfigService.load('FB_APP_ID', ''),
      GlobalConfigService.load('FB_APP_SECRET', '')
    )

    long_lived = exchange_for_long_lived(oauth, token)
    profile = Koala::Facebook::API.new(long_lived[:token]).get_object('me', fields: 'id,name')

    unless profile['id'].to_s == fb_user_id.to_s
      return Result.new(success: false, error: 'O usuário do token não corresponde ao informado pelo popup.')
    end

    store_connection(
      fb_user_id: profile['id'],
      nome: profile['name'],
      token: long_lived[:token],
      expires_at: long_lived[:expires_at],
      conectado_por: conectado_por
    )

    Result.new(success: true, data: { 'fb_user_id' => profile['id'], 'nome' => profile['name'] })
  rescue Koala::Facebook::OAuthTokenRequestError => e
    Rails.logger.error "Meta::ClientAccessService: OAuth falhou: #{e.message}"
    Result.new(success: false, error: "Login do Facebook falhou: #{e.message}")
  rescue StandardError => e
    Rails.logger.error "Meta::ClientAccessService: #{e.class} #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao salvar o acesso do cliente.')
  end

  # Consulta a app na Meta e compara PERMISSOES_REQUERIDAS com o que consta
  # como "live" em /{app_id}/permissions. Diagnóstico pro painel: se alguma
  # permissão do escopo não estiver disponível na app, é isso que faz o
  # cliente tomar "este app precisa de pelo menos uma supported permission"
  # — mesmo com o app verificado, as permissões precisam estar habilitadas
  # (produtos + App Review) e a app precisa estar em modo Live.
  def self.verificar_permissoes
    app_id = GlobalConfigService.load('FB_APP_ID', '').to_s
    secret = GlobalConfigService.load('FB_APP_SECRET', '').to_s
    return Result.new(success: false, error: 'FB_APP_ID/FB_APP_SECRET ausentes no GlobalConfig.') if app_id.blank? || secret.blank?

    api = Koala::Facebook::API.new("#{app_id}|#{secret}")
    lista = (api.get_object("/#{app_id}/permissions", {}, api_version: API_VERSION) || []).each_with_object({}) do |p, h|
      h[p['permission']] = p['status']
    end

    statuses = PERMISSOES_REQUERIDAS.map do |perm|
      { 'permissao' => perm, 'status' => lista[perm] == 'live' ? 'ok' : 'ausente' }
    end

    Result.new(success: true, data: [{ 'permissoes' => statuses, 'app_id' => app_id }])
  rescue Koala::Facebook::ClientError => e
    Rails.logger.error "Meta::ClientAccessService: verificar_permissoes: #{e.message}"
    Result.new(success: false, error: "Falha ao consultar a app na Meta: #{e.fb_error_message || e.message}")
  rescue StandardError => e
    Rails.logger.error "Meta::ClientAccessService: verificar_permissoes: #{e.class} #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao verificar as permissões da app.')
  end

  # Lista as conexões de clientes já concedidas (uma entrada por usuário do
  # Facebook que autorizou), com validade do token.
  def self.conexoes
    clientes = stored_clientes
    lista = clientes.map do |fb_user_id, dados|
      {
        'fb_user_id' => fb_user_id,
        'nome' => dados['nome'],
        'conectado_em' => dados['conectado_em'],
        'expires_at' => dados['expires_at'],
        'valido' => token_valido?(dados)
      }
    end
    Result.new(success: true, data: [{ 'conexoes' => lista }])
  end

  # Devolve o token long-lived do cliente (nil se não conectado/expirado) —
  # usado pelo MetaInfrastructureController pro modo "operar com o token do
  # cliente" dos passos existentes.
  def self.token_para(fb_user_id)
    return nil if fb_user_id.blank?

    dados = stored_clientes[fb_user_id.to_s]
    return nil if dados.blank? || !token_valido?(dados)

    dados['token']
  end

  def self.desconectar(fb_user_id)
    hook = Integrations::Hook.account_hooks.find_by(app_id: HOOK_APP_ID)
    return Result.new(success: true, data: { 'desconectado' => true }) if hook.blank?

    clientes = stored_clientes
    clientes.delete(fb_user_id.to_s)
    hook.update!(settings: (hook.settings || {}).merge('clientes' => clientes))
    Result.new(success: true, data: { 'desconectado' => true })
  rescue StandardError => e
    Rails.logger.error "Meta::ClientAccessService: desconectar #{fb_user_id}: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao remover o acesso do cliente.')
  end

  class << self
    private

    def exchange_for_long_lived(oauth, short_lived_token)
      info = oauth.exchange_access_token_info(short_lived_token) || {}
      token = info['access_token'].presence || short_lived_token
      expires_at = if info['expires_at'].present?
                     Time.zone.at(info['expires_at'].to_i)
                   elsif info['expires_in'].present?
                     Time.zone.now + info['expires_in'].to_i.seconds
                   elsif info['expires'].present?
                     # Facebook já devolveu `expires` como epoch num formato e
                     # como "segundos até expirar" noutro — trata pelos dois.
                     if info['expires'].to_i > 1_000_000_000
                       Time.zone.at(info['expires'].to_i)
                     else
                       Time.zone.now + info['expires'].to_i.seconds
                     end
                   end
      { token: token, expires_at: expires_at }
    end

    def store_connection(fb_user_id:, nome:, token:, expires_at:, conectado_por:)
      hook = Integrations::Hook.account_hooks.find_or_initialize_by(app_id: HOOK_APP_ID)
      clientes = (hook.settings || {})['clientes'] || {}
      clientes[fb_user_id] = {
        'nome' => nome,
        'token' => token,
        'expires_at' => expires_at&.iso8601,
        'conectado_por' => conectado_por,
        'conectado_em' => Time.current.iso8601
      }
      hook.settings = (hook.settings || {}).merge('clientes' => clientes)
      hook.save!
    end

    def stored_clientes
      hook = Integrations::Hook.account_hooks.find_by(app_id: HOOK_APP_ID)
      ((hook&.settings || {})['clientes'] || {})
    end

    def add_grant(grant, criado_por, nome)
      hook = Integrations::Hook.account_hooks.find_or_initialize_by(app_id: HOOK_APP_ID)
      grants = (hook.settings || {})['grants'] || {}
      grants[grant] = {
        'criado_por' => criado_por,
        'nome' => nome.to_s.presence,
        'criado_em' => Time.current.iso8601
      }
      hook.settings = (hook.settings || {}).merge('grants' => grants)
      hook.save!
    end

    def grant_para(grant)
      hook = Integrations::Hook.account_hooks.find_by(app_id: HOOK_APP_ID)
      ((hook&.settings || {})['grants'] || {})[grant.to_s]
    end

    def delete_grant(grant)
      hook = Integrations::Hook.account_hooks.find_by(app_id: HOOK_APP_ID)
      return if hook.blank?

      grants = (hook.settings || {})['grants'] || {}
      grants.delete(grant.to_s)
      hook.update!(settings: (hook.settings || {}).merge('grants' => grants))
    end

    def token_valido?(dados)
      return false if dados['token'].blank?

      expira = begin
        dados['expires_at'].present? ? Time.zone.parse(dados['expires_at']) : nil
      rescue ArgumentError
        nil
      end
      expira.blank? || expira > Time.current
    end
  end
end
