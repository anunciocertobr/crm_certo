require 'cgi'
require 'securerandom'

# Meta::SolicitarCriativoService — fluxo de "Solicitar Criativo" (aba nova na
# página Criação Meta): a equipe escolhe uma pasta de destino (Google Drive ou
# Dropbox) e gera um link público pra mandar ao cliente. O cliente abre o link
# sem estar logado no CRM, preenche o gestor de criativos e os arquivos caem
# na pasta escolhida — cada link fica amarrado a uma pasta específica, então
# clientes diferentes podem usar pastas diferentes.
#
# Mesmo padrão do Meta::ClientAccessService: o link carrega um segredo único
# (grant) armazenado num hook account (app_id 'meta_solicitar_criativo'); quem
# tiver o link pode submeter. A diferença é que o grant NÃO expira no primeiro
# uso (o cliente pode enviar várias vezes no mesmo link) — a pasta de destino
# continua sendo a do grant enquanto o link estiver ativo.
class Meta::SolicitarCriativoService
  HOOK_APP_ID = 'meta_solicitar_criativo'.freeze

  # Limites pra proteção: arquivo grande demais é rejeitado no controller
  # público (o arquivo atravessa o servidor até o Drive/Dropbox).
  MAX_UPLOAD_BYTES = 100 * 1024 * 1024
  MAX_FILES = 20

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  # Gera um link PÚBLICO amarrado a uma pasta de destino. `pasta_ref` é o id
  # da pasta no Drive ou o caminho da pasta no Dropbox (mesmo valor `ref` que
  # a Biblioteca de mídias devolve) — escolhida ANTES de gerar o link, logo
  # cada cliente pode apontar pra uma pasta diferente.
  def self.gerar_link(criado_por:, nome:, provedor:, pasta_ref:, pasta_nome:)
    return Result.new(success: false, error: 'Provedor deve ser drive ou dropbox.') unless %w[drive dropbox].include?(provedor)
    return Result.new(success: false, error: 'Escolha a pasta de destino antes de gerar o link.') if pasta_ref.blank?

    frontend_url = ENV['FRONTEND_URL'].presence
    return Result.new(success: false, error: 'FRONTEND_URL não configurado no ambiente.') if frontend_url.blank?

    grant = SecureRandom.hex(16)
    add_grant(grant, {
                'criado_por' => criado_por,
                'nome' => nome.to_s.presence,
                'provedor' => provedor,
                'pasta_ref' => pasta_ref,
                'pasta_nome' => pasta_nome.to_s.presence
              })

    url = "#{frontend_url.gsub(%r{/+\z}, '')}/solicitar-criativo.html?grant=#{grant}"
    Result.new(success: true, data: { 'url' => url, 'grant' => grant })
  end

  # Valida um grant (link) no endpoint público e devolve metadados que a
  # página do cliente mostra (ex.: pra qual pasta vai o envio). Sem arquivos.
  def self.grant_info(grant)
    meta = grant_para(grant)
    return Result.new(success: false, error: 'Link de solicitação inválido ou expirado.') if meta.blank?

    Result.new(success: true, data: {
                 'nome' => meta['nome'],
                 'provedor' => meta['provedor'],
                 'pasta_nome' => meta['pasta_nome'],
                 'criado_em' => meta['criado_em']
               })
  end

  # Endpoint PÚBLICO: recebe os arquivos do cliente + campos do formulário e
  # faz upload pra pasta amarrada ao grant. Retorna arquivos enviados. O grant
  # continua válido pra próximas submissões (o cliente pode mandar mais).
  def self.receber_submissao(grant:, campos:, arquivos:)
    meta = grant_para(grant)
    return Result.new(success: false, error: 'Link de solicitação inválido ou expirado.') if meta.blank?

    preparado = preparar_arquivos(arquivos)
    return Result.new(success: false, error: preparado) if preparado.is_a?(String)

    enviados = subir_arquivos(meta, preparado)
    return Result.new(success: false, error: enviados) if enviados.is_a?(String)

    registrar_submissao(grant, campos, enviados)
    Result.new(success: true, data: {
                 'nome' => meta['nome'],
                 'arquivos' => enviados,
                 'enviado_em' => Time.current.iso8601
               })
  rescue StandardError => e
    Rails.logger.error "Meta::SolicitarCriativoService: receber_submissao #{e.class} #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao receber os arquivos.')
  end

  # Lista os links gerados com o status de cada um (quantas submissões, última
  # data) — pra aba do dashboard acompanhar quem já mandou o quê.
  def self.solicitacoes
    hook = Integrations::Hook.account_hooks.find_by(app_id: HOOK_APP_ID)
    grants = ((hook&.settings || {})['grants'] || {})
    submissoes = ((hook&.settings || {})['submissoes'] || {})

    lista = grants.map { |grant, meta| dado_solicitacao(grant, meta, submissoes) }
    lista.sort_by! { |s| s['criado_em'].to_s }.reverse!
    Result.new(success: true, data: [{ 'solicitacoes' => lista }])
  end

  class << self
    private

    def preparar_arquivos(arquivos)
      # Solicitações de campanha/edição (formulários sem mídia) são válidas:
      # só o studio ("Enviar Mídia") exige ao menos um arquivo, e a própria
      # página já bloqueia o envio vazio nesse modo.
      selecionados = Array(arquivos).select { |f| f.present? && f.respond_to?(:original_filename) }
      return [] if selecionados.empty?

      erro = validar_arquivos(selecionados)
      return erro if erro

      selecionados
    end

    def validar_arquivos(arquivos)
      return "Máximo de #{MAX_FILES} arquivos por envio." if arquivos.size > MAX_FILES

      arquivos.each do |arquivo|
        erro = validar_arquivo(arquivo)
        return erro if erro
      end
      nil
    end

    def subir_arquivos(meta, arquivos)
      enviados = []
      arquivos.each do |arquivo|
        result = subir(meta['provedor'], meta['pasta_ref'], arquivo)
        return result.error unless result.success

        enviados << { 'nome' => arquivo.original_filename, 'tamanho' => arquivo.size }
      end
      enviados
    end

    def dado_solicitacao(grant, meta, submissoes)
      envios = submissoes[grant] || []
      {
        'grant' => grant,
        'url' => link_url(grant),
        'nome' => meta['nome'],
        'provedor' => meta['provedor'],
        'pasta_ref' => meta['pasta_ref'],
        'pasta_nome' => meta['pasta_nome'],
        'criado_por' => meta['criado_por'],
        'criado_em' => meta['criado_em'],
        'submissoes' => envios.size,
        'arquivos' => envios.sum { |e| e['arquivos'].size },
        'ultima_submissao' => envios.filter_map { |e| e['criado_em'] }.max
      }
    end

    def link_url(grant)
      frontend_url = ENV['FRONTEND_URL'].to_s.gsub(%r{/+\z}, '')
      frontend_url.present? ? "#{frontend_url}/solicitar-criativo.html?grant=#{grant}" : nil
    end

    def validar_arquivo(arquivo)
      return 'Arquivo grande demais (limite de 100MB por arquivo).' if arquivo.size.to_i > MAX_UPLOAD_BYTES
      return 'Nome de arquivo vazio.' if arquivo.original_filename.blank?
    end

    def subir(provedor, pasta_ref, arquivo)
      content = arquivo.read

      if provedor == 'drive'
        Google::DriveService.new.upload_file(
          name: arquivo.original_filename.to_s,
          content: content,
          content_type: arquivo.content_type.presence || 'application/octet-stream',
          parent_id: pasta_ref.presence
        )
      else
        Dropbox::FilesService.new.upload(
          path: [pasta_ref.to_s.gsub(%r{\A/+}, ''), arquivo.original_filename.to_s].reject(&:blank?).join('/'),
          content: content
        )
      end
    end

    def registrar_submissao(grant, campos, arquivos)
      hook = Integrations::Hook.account_hooks.find_or_initialize_by(app_id: HOOK_APP_ID)
      submissoes = (hook.settings || {})['submissoes'] || {}
      submissoes[grant] ||= []

      sanitized = campos.to_h.transform_values { |v| v.is_a?(String) ? v.to_s[0, 5000] : v.to_s }

      submissoes[grant] << {
        'id' => SecureRandom.hex(8),
        'criado_em' => Time.current.iso8601,
        'campos' => sanitized,
        'arquivos' => arquivos
      }
      hook.settings = (hook.settings || {}).merge('submissoes' => submissoes)
      hook.save!
    end

    def add_grant(grant, dados)
      hook = Integrations::Hook.account_hooks.find_or_initialize_by(app_id: HOOK_APP_ID)
      grants = (hook.settings || {})['grants'] || {}
      grants[grant] = {
        'nome' => dados['nome'],
        'provedor' => dados['provedor'],
        'pasta_ref' => dados['pasta_ref'],
        'pasta_nome' => dados['pasta_nome'],
        'criado_por' => dados['criado_por'],
        'criado_em' => Time.current.iso8601
      }
      hook.settings = (hook.settings || {}).merge('grants' => grants)
      hook.save!
    end

    def grant_para(grant)
      hook = Integrations::Hook.account_hooks.find_by(app_id: HOOK_APP_ID)
      ((hook&.settings || {})['grants'] || {})[grant.to_s]
    end
  end
end