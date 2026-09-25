# frozen_string_literal: true

# Meta::SolicitarCriativoAiService — geração de textos (principal, título e
# descrição) com IA para a página pública "Solicitar Criativo". Mesmo padrão
# dos endpoints públicos da aba (o grant valida o link do cliente), mas com o
# proxy de IA do lado do servidor — as chaves (Groq/Gemini/OpenAI) ficam na
# conta (integrations_hooks / Ai::CredentialResolver) e nunca vão pro
# navegador, exatamente como o ToolsProxyController faz pras ferramentas do
# Marketing. O cliente que tiver o link pode gerar os textos da própria
# solicitação usando as credenciais de IA da empresa.
class Meta::SolicitarCriativoAiService
  GROQ_BASE = 'https://api.groq.com'
  GEMINI_BASE = 'https://generativelanguage.googleapis.com'
  OPENAI_BASE = 'https://api.openai.com'

  PROVIDER_LABELS = { 'groq' => 'Groq', 'openai' => 'ChatGPT (OpenAI)', 'gemini' => 'Gemini' }.freeze

  # Prompt de sistema embutido no texto enviado ao modelo: a resposta tem que
  # ser UM JSON com as três chaves que a página preenche, sem markdown — a
  # extração no servidor confia nesse formato.
  SISTEMA = <<~TXT
    Você é um redator sênior de anúncios para Meta (Facebook e Instagram),
    especialista em tráfego pago. Responda SOMENTE com um JSON válido, sem
    markdown e sem comentários, com exatamente estas 3 chaves:
    {"principal":"...","titulo":"...","descricao":"..."}.
    Regras: "principal" = texto principal persuasivo com 3 a 5 frases curtas,
    com chamada para ação; "titulo" = título chamativo com no máximo 40
    caracteres; "descricao" = descrição curta exibida no rodapé do feed, com
    no máximo 30 caracteres. Use um tom coerente com as instruções do usuário.
  TXT

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  # GET /public/api/v1/meta_client/criativos/:grant/ai_models/:provider
  # Lista os modelos disponíveis pro provedor escolhido (filtrados do mesmo
  # jeito que o Marketing AI Tools filtra: sem TTS, sem guard-rails).
  def self.ai_models(grant:, provider:)
    valido = validar_grant(grant)
    return valido unless valido.success

    credencial = credencial(provider)
    return sem_credencial(provider) if credencial[:key].blank?

    modelos = buscar_modelos(provider, credencial)
    Result.new(success: true, data: { 'provedor' => provider, 'modelos' => modelos })
  rescue StandardError => e
    Rails.logger.error "Meta::SolicitarCriativoAiService: ai_models #{e.class} #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao listar os modelos de IA.')
  end

  # POST /public/api/v1/meta_client/criativos/gerar_textos
  # Gera principal/título/descrição com o provedor+modelo escolhidos e o
  # prompt livre da página. Devolve as três strings prontas pra preencher.
  def self.gerar_textos(grant:, provider:, model:, prompt:)
    valido = validar_grant(grant)
    return valido unless valido.success

    credencial = credencial(provider)
    return sem_credencial(provider) if credencial[:key].blank?

    prompt_final = montar_prompt(prompt)
    texto = chamar_modelo(provider, credencial, model, prompt_final)
    return Result.new(success: false, error: 'Erro ao chamar o provedor de IA. Tente novamente.') if texto.blank?

    campos = extrair_campos(texto)
    return Result.new(success: false, error: 'A IA não retornou os textos no formato esperado. Tente novamente.') if campos.nil?

    Result.new(success: true, data: campos)
  rescue StandardError => e
    Rails.logger.error "Meta::SolicitarCriativoAiService: gerar_textos #{e.class} #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao gerar os textos.')
  end

  class << self
    private

    def validar_grant(grant)
      valido = Meta::SolicitarCriativoService.grant_info(grant)
      valido.success ? Result.new(success: true, data: nil) : Result.new(success: false, error: valido.error)
    end

    def credencial(provider)
      case provider
      when 'groq', 'gemini'
        key = Integrations::Hook.account_hooks.find_by(app_id: provider)&.settings&.dig('api_key').presence
        { key: key, base_url: nil }
      when 'openai'
        endpoint = Ai::CredentialResolver.resolve_endpoint(for_consumer: :marketing_ai_tools)
        { key: endpoint&.key.presence, base_url: endpoint&.base_url.presence }
      else
        {}
      end
    end

    def sem_credencial(provider)
      Result.new(success: false, error: "Credencial #{PROVIDER_LABELS[provider] || 'de IA'} não configurada. Adicione em Configurações > IA.")
    end

    def buscar_modelos(provider, credencial)
      response =
        case provider
        when 'groq'
          HTTParty.get("#{GROQ_BASE}/openai/v1/models", headers: cabecalho(credencial[:key]))
        when 'openai'
          HTTParty.get("#{credencial[:base_url].presence || OPENAI_BASE}/v1/models", headers: cabecalho(credencial[:key]))
        else
          HTTParty.get("#{GEMINI_BASE}/v1beta/models?key=#{credencial[:key]}")
        end
      return [] unless response.success?

      filtrar_modelos(provider, response.parsed_response)
    end

    def filtrar_modelos(provider, body)
      if provider == 'gemini'
        (body['models'] || [])
          .select { |m| (m['supportedGenerationMethods'] || []).include?('generateContent') }
          .map { |m| { 'id' => m['name'].to_s.sub(%r{\Amodels/}, ''), 'label' => m['displayName'].presence || m['name'] } }
      else
        (body['data'] || [])
          .reject { |m| m['id'].to_s.match?(/whisper|orpheus|prompt-guard/i) }
          .map { |m| { 'id' => m['id'], 'label' => m['id'] } }
      end
    end

    def chamar_modelo(provider, credencial, model, prompt)
      if provider == 'gemini'
        modelo = model.presence || 'gemini-1.5-flash-latest'
        response = HTTParty.post(
          "#{GEMINI_BASE}/v1beta/models/#{modelo}:generateContent?key=#{credencial[:key]}",
          headers: { 'Content-Type' => 'application/json' },
          body: { contents: [{ parts: [{ text: prompt }] }] }.to_json
        )
        return nil unless response.success?

        response.parsed_response.dig('candidates', 0, 'content', 'parts', 0, 'text')
      else
        modelo = model.presence || (provider == 'openai' ? 'gpt-4o-mini' : 'llama-3.3-70b-versatile')
        base = provider == 'openai' ? (credencial[:base_url].presence || OPENAI_BASE) : GROQ_BASE
        url = provider == 'groq' ? "#{base}/openai/v1/chat/completions" : "#{base}/v1/chat/completions"
        response = HTTParty.post(
          url,
          headers: cabecalho(credencial[:key]),
          body: {
            model: modelo,
            messages: [{ role: 'user', content: prompt }],
            temperature: 0.8
          }.to_json
        )
        return nil unless response.success?

        response.parsed_response.dig('choices', 0, 'message', 'content')
      end
    end

    def cabecalho(key)
      { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{key}" }
    end

    def montar_prompt(prompt)
      instrucoes = prompt.to_s.strip.presence || 'Crie textos persuasivos para um anúncio de tráfego no Facebook e Instagram.'
      "#{SISTEMA}\n\nInstruções do usuário: #{instrucoes}"
    end

    # Extrai o JSON da resposta (a IA pode envolver em aspas/código) e valida
    # que as três chaves vieram preenchidas.
    def extrair_campos(texto)
      json = texto.to_s.match(/\{.*\}/m)&.[](0)
      return nil if json.nil?

      parsed = JSON.parse(json)
      return nil unless parsed.is_a?(Hash)

      %w[principal titulo descricao].each do |chave|
        return nil if parsed[chave].to_s.strip.blank?
      end

      {
        'principal' => parsed['principal'].to_s.strip,
        'titulo' => parsed['titulo'].to_s.strip,
        'descricao' => parsed['descricao'].to_s.strip
      }
    rescue JSON::ParserError
      nil
    end
  end
end