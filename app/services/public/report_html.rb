# frozen_string_literal: true

module Public
  # Prepara o relatório HTML do item "Relatórios" do Dashboard para ser servido
  # a um cliente, sem login e sem Personal Access Token.
  #
  # POR QUE SERVIR O HTML E NÃO REESCREVER A PÁGINA
  # O item `dashboard-menu-items`/mtlsot4v-cf6f9s é um HTML de ~131 KB escrito
  # à mão, com Chart.js (28 <canvas>), Leaflet, Tailwind e abas de Meta Ads,
  # Google Ads, GA4 e mapa. Ele já funciona sozinho: busca tudo por /api/v1/...
  # e NÃO depende do CRM (não tem listener de postMessage, o iframe só manda
  # dados que ele ignora). Então a página pública é esse mesmo arquivo, e os
  # gráficos ficam idênticos por construção em vez de eu tentar reproduzir 28
  # gráficos e errar as cores, os filtros e a responsividade.
  #
  # A ÚNICA MUDANÇA NECESSÁRIA É O TOKEN
  # O HTML tem um IIFE que anexa `api_access_token: DASHBOARD_API_TOKEN` em
  # toda chamada /api/. Trocamos essa constante pelo token do link e apontamos
  # as chamadas para /public/api/..., que valida o token do link e só devolve
  # as contas que o dono marcou. O `menu_configs` NÃO é alterado: a tela
  # interna continua usando o PAT como sempre.
  #
  # SEGURANÇA — FALHA FECHADA
  # Se o HTML do menu mudar de forma que a constante do token não exista mais
  # (ou exista duplicada), a página NÃO é servada: 500 em vez de vazar o PAT
  # original para o cliente sem nenhum erro visível. E o valor capturado da
  # constante é conferido de novo no HTML final. Ver `replace_token`.
  class ReportHtml
    SCOPE = 'dashboard-menu-items'
    ITEM_ID = 'mtlsot4v-cf6f9s'

    TOKEN_CONST = /const DASHBOARD_API_TOKEN = '([^']*)';/.freeze

    # Substitui `DASHBOARD_API_BASE + url` por uma chamada sob /public/api/.
    # O wrapper original só reescreve o que começa com '/api/', então
    # prefixar '/public' mantém a detecção funcionando e leva as chamadas para
    # os controllers públicos, que exigem o token do link.
    API_JOIN = 'DASHBOARD_API_BASE + url'
    PUBLIC_API_JOIN = "DASHBOARD_API_BASE + '/public' + url"

    class RenderError < StandardError; end

TOKEN_CONST_ERROR =
      'A constante DASHBOARD_API_TOKEN não foi encontrada exatamente uma vez no relatório. ' \
      'Publicar assim pode enviar o Personal Access Token ao cliente.'
    SECRET_LEAK_ERROR = 'O Personal Access Token continua no relatório público.'
    API_JOIN_ERROR =
      "O relatório mudou e não usa mais '#{API_JOIN}'. As chamadas deixariam de passar " \
      'pelas rotas públicas, que são as que checam o token e as contas do link.'

    def initialize(link)
      @link = link
    end

    def call
      html = source_html
      raise RenderError, "Item #{ITEM_ID} do Dashboard não encontrado." if html.blank?

      html = replace_token(html)
      html = rewrite_api_calls(html)
      html = inject_bootstrap(html)
      html
    end

    private

    attr_reader :link

    def source_html
      items = MenuConfig.find_by(scope: SCOPE)&.payload
      Array(items.is_a?(Hash) ? items['items'] : items)
           .find { |i| i.is_a?(Hash) && i['id'] == ITEM_ID }
           &.dig('html')
    end

    # FALHA FECHADA (fail closed). Se o HTML do menu mudar de forma que a
    # constante não exista mais, ou exista duplicada, a página NÃO é servida.
    #
    # Não dá para "consertar" isso caçando qualquer string longa no HTML: os
    # hashes de integridade do CDN (integrity="sha256-p4NxAoJBhIIN...") e
    # identificadores JS longos casam com qualquer heurística de entropia e
    # derrubariam a página na maioria das vezes. O risco real é estreito e
    # nomeado — o valor dessa constante —, então é ele que é conferido:
    #
    # 1. a constante precisa existir exatamente uma vez;
    # 2. o valor original é capturado antes de trocar;
    # 3. depois de todas as transformações, esse valor não pode estar na página.
    def replace_token(html)
      matches = html.scan(TOKEN_CONST)
      raise RenderError, TOKEN_CONST_ERROR if matches.size != 1

      secret = matches.first.first
      # Aspas simples como no HTML original. O token é urlsafe_base64 (só
      # [A-Za-z0-9_-]), então não há como a string fechar a aspa.
      rendered = html.sub(TOKEN_CONST, "const DASHBOARD_API_TOKEN = '#{link.token}';")

      raise RenderError, 'O token do link não foi injetado no relatório.' unless rendered.include?(link.token)
      raise RenderError, SECRET_LEAK_ERROR if secret.present? && rendered.include?(secret)

      rendered
    end

    # O wrapper original só reescreve o que começa com '/api/', então prefixar
    # '/public' mantém a detecção funcionando e leva as chamadas para os
    # controllers públicos, que exigem o token do link e checam a conta pedida.
    def rewrite_api_calls(html)
      raise RenderError, API_JOIN_ERROR unless html.include?(API_JOIN)

      html.gsub(API_JOIN, PUBLIC_API_JOIN)
    end

    # Script pequeno inserido logo DEPOIS da tag <head>, antes de qualquer
    # script do relatório:
    #
    # - pré-seleciona a conta do link. O HTML escolhe a conta por cookie
    #   (`getCookie('metaAdAccountId')`, linha ~494 do original) e um cliente
    #   novo não tem cookie nenhum — sem isso a página abriria pedindo
    #   "selecione uma conta". Precisa ser síncrono aqui no head: se a
    #   atribuição ficasse para DOMContentLoaded, o script do relatório já
    #   teria lido o cookie vazio.
    # - bloqueia escrita no navegador. O relatório tem células editáveis que
    #   fazem PATCH em /whatsapp_ad_leads/:id e um link público não pode
    #   alterar nada. É defesa em profundidade: a rota pública de escrita nem
    #   existe (404), mas o cliente receberia um 403 em vez de um erro seco.
    # - esconde a aba de Leads, que traz nome e telefone de clientes.
    def inject_bootstrap(html)
      script = <<~JS
        <script data-evo-public-report>
        window.__EVO_PUBLIC_REPORT__ = { accountId: #{link.ad_account_ids.first.inspect} };
        try {
          document.cookie = 'metaAdAccountId=' +
            encodeURIComponent(window.__EVO_PUBLIC_REPORT__.accountId || '') +
            '; path=/; SameSite=Lax';
        } catch (e) { /* cookie bloqueado: a página abre sem conta pré-selecionada */ }
        (function () {
          var nativeFetch = window.fetch.bind(window);
          window.fetch = function (input, init) {
            var opts = init || {};
            var method = (opts.method || 'GET').toUpperCase();
            if (method !== 'GET' && method !== 'HEAD') {
              return Promise.resolve(new Response(
                JSON.stringify({ error: 'Relatório somente leitura.' }),
                { status: 403, headers: { 'Content-Type': 'application/json' } }
              ));
            }
            return nativeFetch(input, opts);
          };
        })();
        </script>
        <style data-evo-public-report>
          /* Leads tem nome, telefone e valor de venda: fora do link público. */
          [data-page='leads-dashboard'] { display: none !important; }
        </style>
      JS

      # Depois da tag de abertura do head, não antes de </head>: os scripts do
      # relatório estão no head e leriam o cookie depois da nossa escrita.
      injected = html.sub(/<head([^>]*)>/) { "<head#{$1}>#{script}" }
      return injected if injected != html

      # HTML sem <head> não é o caso esperado, mas não devemos devolver a
      # página sem a pré-seleção de conta silenciosamente.
      raise RenderError, 'Relatório sem tag <head>: não foi possível pré-selecionar a conta.'
    end
  end
end