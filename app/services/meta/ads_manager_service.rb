require 'net/http'
require 'base64'
require 'securerandom'
require 'digest'

# Meta::AdsManagerService - substitui o workflow n8n "painel meta relatorios
# campanhas gerenciador de anuncio" (o "Painel Tráfego"): navegar
# contas -> campanhas -> conjuntos -> anúncios -> criativo, editar
# campanha/conjunto/anúncio (nome/status/orçamento/criativo), duplicar
# anúncio e criar campanha nova (campanha+conjunto+anúncio+criativo, num
# fluxo só, igual o modal "Criar Campanha" do painel_trafego.html monta).
# Usa o mesmo user_access_token de Channel::FacebookPage que
# Meta::AdsInsightsService (precisa do escopo ads_read/ads_management).
#
# Os métodos devolvem exatamente a forma que
# dashboards-src/painel_trafego.html já espera do n8n (arrays com uma
# posição, campos "dados campanhas"/"insights", body.success) — o HTML só
# trocou a URL que chama, a lógica de renderização é a mesma.
class Meta::AdsManagerService
  BASE_URL = 'https://graph.facebook.com/v23.0'

  # Campos que a UI de edição realmente expõe — nunca repassa o `edicao` cru
  # pra API sem passar por este filtro, mesmo a origem sendo confiável
  # (defesa em profundidade: um bug no front não vira uma escrita arbitrária
  # na Graph API).
  EDITABLE_FIELDS = {
    'campaign' => %w[name status objective daily_budget lifetime_budget],
    'adset' => %w[name status daily_budget lifetime_budget targeting],
    'ad' => %w[name status ad_creative]
  }.freeze

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize(access_token: nil)
    # access_token: token long-lived de um CLIENTE conectado na aba
    # "Conceder Acessos" (Meta::ClientAccessService). Nesse modo a Página
    # global (Channel::FacebookPage) NÃO é usada — recursos que dependem
    # dela (criativos com página, formulários de leads) não funcionam com
    # o token do cliente e devolvem erro honesto.
    @page = access_token.present? ? nil : Channel::FacebookPage.first
    @token = access_token || @page&.user_access_token
  end

  def connected?
    @token.present?
  end

  # business_id: quando presente, escopa às contas dessa Business Manager
  # (donas + clientes) em vez do /me/adaccounts global — usado pelo nível
  # "BM" do Painel Tráfego (BM > Contas > Campanhas > ...).
  # date_start/date_stop: período escolhido no Painel Tráfego (Hoje/Semana/
  # Mês/Últimos 30 dias/Ano/Máximo/Customizado). Antes este método ignorava
  # esses parâmetros por completo e sempre buscava date_preset=last_30d —
  # por isso o Gasto/Impressões/etc. no nível de Contas nunca mudava,
  # independente do período selecionado na UI (só o drill-down de
  # campanhas respeitava o período). Se vierem ausentes, cai de volta pra
  # last_30d (mesmo comportamento de antes).
  def ad_accounts(business_id: nil, date_start: nil, date_stop: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    fields = 'id,name,account_id,balance,spend_cap,is_prepay_account,amount_spent,currency'
    if business_id.present?
      owned = get("/#{business_id}/owned_ad_accounts", fields: fields)
      return owned unless owned.success

      client = get("/#{business_id}/client_ad_accounts", fields: fields)
      return client unless client.success

      raw_accounts = (owned.data + client.data).uniq { |a| a['id'] }
    else
      result = get('/me/adaccounts', fields: fields)
      return result unless result.success

      raw_accounts = result.data
    end

    insight_fields = 'impressions,reach,spend,clicks,cpc,ctr,actions'
    period_params = if date_start.present? && date_stop.present?
                      { time_range: { since: date_start, until: date_stop }.to_json }
                    else
                      { date_preset: 'last_30d' }
                    end

    # Uma request HTTP por conta, em série, estourava o timeout de 15s do
    # Rack::Timeout assim que o token tinha mais de ~10 contas (visto em
    # produção com 25 contas -> 500). Em paralelo, o tempo total passa a ser
    # o da conta mais lenta, não a soma de todas.
    #
    # Duas buscas por conta (não uma): "insights" segue o período escolhido
    # na UI (pro Gasto/Impressões/etc. dos cards), e "insights_30d" fica
    # SEMPRE fixo em last_30d, só pra alimentar o cálculo de dias restantes
    # de orçamento (computeDaysLeft no front) — esse cálculo precisa de uma
    # janela conhecida e estável (30 dias) no denominador, senão trocar o
    # período pra "Hoje" faria a conta achar que o saldo dura só 1 dia de
    # gasto. Lançar as duas junto (não uma leva depois da outra) evita
    # dobrar a latência total.
    insights_by_id = Concurrent::Hash.new
    days_left_insights_by_id = Concurrent::Hash.new
    threads = raw_accounts.flat_map do |account|
      [
        Thread.new do
          insights_by_id[account['id']] = get(
            "/#{account['id']}/insights",
            { fields: insight_fields, level: 'account' }.merge(period_params)
          )
        end,
        Thread.new do
          days_left_insights_by_id[account['id']] = get(
            "/#{account['id']}/insights",
            fields: 'spend', level: 'account', date_preset: 'last_30d'
          )
        end
      ]
    end
    threads.each(&:join)

    accounts = raw_accounts.map do |account|
      insights = insights_by_id[account['id']]
      days_left_insights = days_left_insights_by_id[account['id']]
      account.merge(
        'id' => account['account_id'] || account['id'].to_s.delete_prefix('act_'),
        'insights' => insights&.success ? insights.data : [],
        'insights_30d' => days_left_insights&.success ? days_left_insights.data : []
      )
    end

    Result.new(success: true, data: [{ 'lista_final_contas_de_anuncios' => accounts }])
  end

  # Busca uma única conta pelo ID — usado pelo botão "Buscar conta" de
  # Metas de Clientes, que preenche o nome da conta a partir só do ID que o
  # usuário colou (sem precisar navegar Business Manager > Contas).
  def account_info(ad_account_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    result = get("/act_#{id}", fields: 'name,account_id,currency,timezone_name,amount_spent')
    return result unless result.success

    Result.new(success: true, data: result.data.merge('id' => result.data['account_id'] || id))
  end

  # Ao escolher uma conta de anúncio em Metas de Clientes, preenche sozinho
  # idade/gênero/localizações a partir do que a conta JÁ rodou (em vez do
  # usuário digitar de cabeça o público que normalmente usa) e traz a
  # árvore campanha > conjunto > anúncio das campanhas ativas agora, com
  # métricas dos últimos 30 dias em cada nível — pra dar contexto (e um
  # jeito de conferir resultado) na hora de montar os objetivos.
  #
  # "Todo o histórico" (idade/gênero/localizações) na prática é limitado
  # aos 300 conjuntos de anúncio mais recentes (sem paginar além disso) —
  # como o resto deste service (ver `campaigns_tree`), uma request só, sem
  # seguir cursor, é o suficiente pra representar o padrão de público da
  # conta sem arriscar timeout numa conta com milhares de conjuntos
  # históricos.
  def account_history_summary(ad_account_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')

    adsets_for_targeting = get("/act_#{id}/adsets", fields: 'targeting', limit: 300)
    return adsets_for_targeting unless adsets_for_targeting.success

    campaigns = get(
      "/act_#{id}/campaigns",
      fields: 'id,name,objective,daily_budget,lifetime_budget,' \
              'adsets{id,name,effective_status,daily_budget,lifetime_budget,ads{id,name,effective_status}}',
      effective_status: %w[ACTIVE].to_json,
      limit: 100
    )
    return campaigns unless campaigns.success

    insights = get(
      "/act_#{id}/insights",
      fields: 'campaign_id,adset_id,ad_id,spend,impressions,reach,clicks,actions',
      level: 'ad',
      date_preset: 'last_30d',
      limit: 500
    )
    insights_by_ad_id = insights.success ? Array(insights.data).index_by { |r| r['ad_id'] } : {}

    Result.new(success: true, data: {
                 'targeting_summary' => summarize_targeting(adsets_for_targeting.data),
                 'active_campaigns' => campaigns.data.map { |c| build_campaign_node(c, insights_by_ad_id) }
               })
  end

  # Lista as Business Managers que o token tem acesso — nível acima de
  # "Contas" no Painel Tráfego.
  def business_managers
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    result = get('/me/businesses', fields: 'id,name')
    return result unless result.success

    Result.new(success: true, data: [{ 'lista_bms' => result.data }])
  end

  # Números de WhatsApp que esta conta de anúncios já usa, para a página
  # escolhida — é o que o painel oferece no seletor quando o destino da
  # conversa é WhatsApp.
  #
  # NÃO dá pra ler a WABA direto: `/{page}/whatsapp_business_accounts`,
  # `/{page}/owned_whatsapp_business_accounts`, `/{waba}/phone_numbers` e
  # `/me/owned_whatsapp_business_accounts` são todos recusados pelo token de
  # Página com "Tried accessing nonexisting field" — eles exigem token de
  # negócio com o escopo `whatsapp_business_management`, que a integração não
  # tem. A saída é ler os próprios conjuntos da conta: todo conjunto de
  # WhatsApp publicado carrega `promoted_object.whatsapp_phone_number` (e o
  # `whatsapp_business_account_data.waba_id` que a Meta resolve sozinha), então
  # os números que a conta consegue usar são exatamente esses.
  def whatsapp_numbers_for_page(page_id:, ad_account_id: nil)
    page_id = page_id.to_s
    return Result.new(success: false, error: 'Escolha a página para listar os números de WhatsApp.') if page_id.blank?
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    account = ad_account_id.to_s.delete_prefix('act_')
    return Result.new(success: false, error: 'Escolha a conta de anúncios para listar os números.') if account.blank?

    # O `promoted_object` da campanha também vale: campanha de leads/WhatsApp
    # costuma ter o objeto promovido no nível da campanha, não do conjunto.
    found = []
    ["/act_#{account}/adsets", "/act_#{account}/campaigns"].each do |path|
      listing = get(path, { fields: 'id,name,promoted_object', limit: 200 })
      next unless listing.success

      Array(listing.data).each do |node|
        promoted = node['promoted_object']
        next unless promoted.is_a?(Hash)
        next if promoted['page_id'].present? && promoted['page_id'].to_s != page_id
        next if promoted['whatsapp_phone_number'].blank?

        waba = promoted['whatsapp_business_account_data'] || promoted['whatsapp_business_account'] || {}
        found << {
          'phone_number' => promoted['whatsapp_phone_number'].to_s,
          'waba_id' => waba.is_a?(Hash) ? (waba['waba_id'].presence || waba['id']) : nil,
          'source' => node['name']
        }
      end
    end

    numbers = found.uniq { |n| n['phone_number'] }
    # Lista vazia é resposta válida: a UI avisa que não há histórico de
    # WhatsApp na conta e deixa o campo aceitar digitação.
    Result.new(success: true, data: numbers)
  end

  def campaigns_tree(ad_account_id:, date_start:, date_stop:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    structural = get(
      "/act_#{ad_account_id}/campaigns",
      fields: 'id,name,status,objective,description,' \
              'adsets{name,status,description,daily_budget,lifetime_budget,targeting,promoted_object,start_time,end_time,' \
              'optimization_goal,bid_strategy,ads{name,status,adcreative{name,body,title,image_url,video_id}}}',
      limit: 200
    )
    return structural unless structural.success

    insights = get(
      "/act_#{ad_account_id}/insights",
      fields: 'campaign_id,campaign_name,adset_id,adset_name,ad_id,ad_name,impressions,reach,spend,clicks,cpc,ctr,actions',
      level: 'ad',
      time_range: { since: date_start, until: date_stop }.to_json,
      limit: 500
    )
    return insights unless insights.success

    Result.new(success: true, data: [{ 'dados campanhas' => { 'data' => structural.data }, 'insights' => { 'data' => insights.data } }])
  end

  # Suporta os 3 formatos de criativo que a Meta Ads tem: imagem única,
  # vídeo único (Reel/Story) e carrossel (child_attachments dentro de
  # object_story_spec.link_data — cada cartão com sua própria imagem/nome/
  # descrição). `titulo`/`texto_principal`/`creativo_nome` sempre vieram do
  # `name`/`body`/`title` achatados do próprio nó creative (mesma leitura
  # que `duplicate_adset_to_campaign` já faz pra duplicar) — faltavam nesta
  # resposta desde sempre, então o front nunca tinha como mostrá-los.
  def creative_details(ad_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    ad = get(
      "/#{ad_id}",
      fields: 'name,creative{name,body,title,image_url,thumbnail_url,video_id,object_story_spec}'
    )
    return ad unless ad.success

    creative = ad.data['creative'] || {}
    video = {}
    if creative['video_id'].present?
      video_result = get("/#{creative['video_id']}", fields: 'permalink_url,source,picture')
      video = video_result.success ? video_result.data : {}
    end

    link_data = creative.dig('object_story_spec', 'link_data') || {}
    video_data = creative.dig('object_story_spec', 'video_data') || {}
    child_attachments = link_data['child_attachments']
    carousel = Array(child_attachments).map do |item|
      { 'imagem' => item['picture'] || item['image_url'], 'nome' => item['name'], 'descricao' => item['description'] }
    end

    # Anúncios de geração de cadastro (e alguns outros formatos) não
    # populam o campo achatado image_url do creative — só existe dentro de
    # object_story_spec.link_data.picture. Sem esse fallback, esses
    # anúncios sempre voltavam "Nenhum criativo encontrado" mesmo tendo
    # imagem de verdade.
    imagem = creative['image_url'] || link_data['picture']

    # `source` (o .mp4 baixável) exige permissão de vídeo que este token não
    # tem — a Graph API simplesmente omite o campo, sem erro. `permalink_url`
    # sempre existe, só que vem RELATIVO ("/<page-id>/videos/<video-id>"),
    # precisa do domínio na frente pra virar um link de verdade. Sem isso, um
    # anúncio em vídeo (bem comum) sempre caía em "Nenhum criativo
    # encontrado" mesmo tendo vídeo de verdade.
    video_url = video['source'] || (video['permalink_url'].present? ? "https://www.facebook.com#{video['permalink_url']}" : nil)
    thumbnail = creative['thumbnail_url'] || video_data['image_url'] || video['picture']

    Result.new(success: true, data: [{
      'imagem' => imagem,
      'video' => video_url,
      'thumbnail_url' => thumbnail,
      'carrossel' => carousel,
      'titulo' => creative['title'],
      'texto_principal' => creative['body'],
      'criativo_nome' => creative['name']
    }])
  end

  # nivel: 'campaign' | 'adset' | 'ad'. edicao: hash já filtrado por
  # EDITABLE_FIELDS pelo controller antes de chegar aqui.
  #
  # `ad_creative` (só existe no nível 'ad') não é um PATCH simples como os
  # outros campos — criativos são imutáveis na Graph API, precisa do fluxo
  # de duas etapas em `update_ad_creative`. Extraído aqui antes do POST
  # genérico pra não tentar mandar um objeto aninhado por `set_form_data`
  # (que só aceita valores escalares).
  def update(id:, edicao:)
    edicao = edicao.dup
    raw_creative = edicao.delete('ad_creative')
    if raw_creative.present?
      creative_edit = raw_creative.is_a?(String) ? JSON.parse(raw_creative) : raw_creative
      creative_result = update_ad_creative(ad_id: id, creative_edit: creative_edit)
      return creative_result unless creative_result.success
    end

    return Result.new(success: true, data: [{ 'body' => { 'success' => true } }]) if edicao.blank?

    result = post("/#{id}", edicao)
    Result.new(success: result.success, data: [{ 'body' => { 'success' => result.success } }], error: result.error)
  end

  # Público personalizado a partir do pixel (visitantes do site) — fonte
  # típica pra criar um público semelhante em cima. `rule` no formato que a
  # Graph API espera pra "todo mundo que visitou o site" numa janela de dias.
  def create_custom_audience_from_pixel(ad_account_id:, pixel_id:, name:, retention_days: 180)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    post("/act_#{ad_account_id}/customaudiences", {
           name: name,
           rule: { inclusions: { operator: 'or', rules: [{ event_sources: [{ id: pixel_id, type: 'pixel' }],
                                                            retention_seconds: retention_days * 86_400,
                                                            filter: { operator: 'and', filters: [{ field: 'url', operator: 'i_contains', value: '' }] } }] } }.to_json,
           customer_file_source: 'USER_PROVIDED_ONLY'
         })
  end

  # Público semelhante a partir de um público de origem já existente
  # (custom audience — inclusive um recém-criado do pixel). Fica
  # "populando" no Meta por um tempo depois de criado; a chamada em si
  # sucede na hora, o tamanho é que demora a aparecer.
  def create_lookalike_audience(ad_account_id:, origin_audience_id:, name:, country: 'BR', ratio: 0.01)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    post("/act_#{ad_account_id}/customaudiences", {
           name: name,
           subtype: 'LOOKALIKE',
           origin_audience_id: origin_audience_id,
           lookalike_spec: { type: 'similarity', country: country, ratio: ratio, starting_ratio: 0.0 }.to_json
         })
  end

  def duplicate_ad(id:, edicao: {})
    result = post("/#{id}/copies", edicao)
    return Result.new(success: false, data: [{ 'body' => { 'success' => false } }], error: result.error) unless result.success

    Result.new(success: true, data: [{ 'body' => { 'success' => true, 'copied_campaign_id' => result.data['copied_ad_id'] || result.data['ad_id'] } }])
  end

  # Objetivo padrão de otimização por objetivo de campanha — usado quando
  # duplicate_with_new_objective não recebe um optimization_goal explícito.
  DEFAULT_OPTIMIZATION_GOAL_BY_OBJECTIVE = {
    'OUTCOME_ENGAGEMENT' => 'CONVERSATIONS',
    'OUTCOME_TRAFFIC' => 'LINK_CLICKS',
    'OUTCOME_SALES' => 'OFFSITE_CONVERSIONS',
    'OUTCOME_LEADS' => 'LEAD_GENERATION'
  }.freeze

  # Duplica uma campanha TROCANDO o objetivo, sem o bug do "Duplicar" nativo
  # do Gerenciador de Anúncios (que, ao trocar o objetivo de uma cópia,
  # costuma perder público/criativo — reclamação recorrente de quem usa o
  # Gerenciador direto). Em vez de usar o endpoint `/copies` da Graph API
  # (usado por duplicate_ad acima, que carrega esse mesmo problema), lê o
  # público e o criativo (imagem/vídeo, título, texto) da campanha de
  # origem e manda tudo de novo por create_campaign_full — o mesmo caminho,
  # já testado, que cria uma campanha do zero. Sempre nasce PAUSADA (é uma
  # campanha nova, não uma edição da original) e usa só o primeiro conjunto/
  # anúncio da origem (mesma granularidade 1:1:1 que create_campaign_full
  # já assume).
  def duplicate_with_new_objective(campaign_id:, ad_account_id:, new_objective:, new_optimization_goal: nil, overrides: {})
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    source = get(
      "/#{campaign_id}",
      fields: 'name,adsets.limit(1){name,daily_budget,targeting,ads.limit(1){name,creative{body,title,image_url,thumbnail_url,video_id,object_story_spec}}}'
    )
    return step_error(source, 'campanha de origem') unless source.success

    adset = source.data.dig('adsets', 'data', 0)
    return Result.new(success: false, error: 'A campanha de origem não tem conjunto de anúncios pra copiar.') if adset.blank?

    ad = adset.dig('ads', 'data', 0)
    return Result.new(success: false, error: 'A campanha de origem não tem anúncio pra copiar.') if ad.blank?

    creative = ad['creative'] || {}
    asset_url = resolve_creative_source_asset(creative)
    return Result.new(success: false, error: 'Não encontrei imagem nem vídeo no anúncio de origem pra reaproveitar.') if asset_url.blank?

    optimization_goal = new_optimization_goal.presence || DEFAULT_OPTIMIZATION_GOAL_BY_OBJECTIVE[new_objective]

    # Sem copiar o link de destino, toda campanha de tráfego/vendas
    # duplicada aponta pra Página do Facebook em vez do site original
    # (build_creative cai no fallback "https://www.facebook.com/<page>")
    # — a cópia "funciona" mas entrega tráfego para o lugar errado.
    link = creative.dig('object_story_spec', 'link_data', 'link').presence

    campanha = {
      'name' => overrides['name'].presence || "#{source.data['name']} (#{new_objective})",
      'status' => 'PAUSED',
      'objective' => new_objective,
      'adset_name' => overrides['adset_name'].presence || adset['name'],
      'adset_status' => 'PAUSED',
      'daily_budget' => overrides['daily_budget'].presence || adset['daily_budget'],
      'optimization_goal' => optimization_goal,
      'bid_strategy' => overrides['bid_strategy'].presence || 'LOWEST_COST_WITHOUT_CAP',
      'ad_name' => overrides['ad_name'].presence || ad['name'],
      'ad_status' => 'PAUSED',
      'title' => overrides['title'].presence || creative['title'],
      'body' => overrides['body'].presence || creative['body'],
      'asset_url' => asset_url,
      'link' => overrides['link'].presence || link,
      'targeting' => adset['targeting'] || {}
    }.merge(adset_level_overrides(overrides)).compact

    create_campaign_full(ad_account_id: ad_account_id, campanha: campanha)
  end

  # Cria campanha + conjunto de anúncios + criativo (upload de imagem/vídeo)
  # + anúncio, na mesma conta, num fluxo só — é o que o modal "Criar
  # Campanha" do painel_trafego.html monta e manda em `campanha` (payload
  # achatado, ver handleCreateCampaign no HTML). Qualquer etapa que falhar
  # para o fluxo e devolve o erro com o nome da etapa, sem tentar limpar as
  # etapas anteriores já criadas (a campanha/conjunto ficam PAUSED mesmo se
  # o resto falhar, então não há gasto — só sujeira pra apagar manualmente).
  def create_campaign_full(ad_account_id:, campanha:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
    return Result.new(success: false, error: 'Página do Facebook sem page_id configurado (necessário pro criativo).') if page_id_for(campanha).blank?

    act = "act_#{ad_account_id}"

    lead_form_id = nil
    if lead_flow?(campanha)
      lead_form = create_lead_form(campanha: campanha)
      return step_error(lead_form, 'formulário de cadastro') unless lead_form.success

      lead_form_id = lead_form.data['id']
    end

    # Orçamento no nível da CAMPANHA (CBO) é opt-in: só entra quando o front
    # manda `campaign_daily_budget`. Sem ele, cada conjunto carrega o seu
    # `daily_budget`.
    #
    # O `is_adset_budget_sharing_enabled: false` é obrigatório nos DOIS casos:
    # (a) orçamento por conjunto sem ele a Graph API recusa com subcode
    # 4834011, e (b) com CBO o flag ligado é recusado com 4834002 ("não pode
    # usar compartilhamento de orçamento do conjunto com o orçamento da
    # campanha"). O que faz a Meta dividir o CBO entre os conjuntos é ela
    # mesma, não esse flag.
    campaign_budget = campanha['campaign_daily_budget'].presence
    adset_budget_shared = campaign_budget.blank?

    campaign = post("/#{act}/campaigns", {
                       name: campanha['name'],
                       status: campanha['status'].presence || 'PAUSED',
                       objective: campanha['objective'],
                       special_ad_categories: [].to_json,
                       is_adset_budget_sharing_enabled: false
                     }.tap do |body|
      body[:daily_budget] = campaign_budget if campaign_budget
    end)
    return step_error(campaign, 'campanha') unless campaign.success

    # `adsets` (novo): array de conjuntos, cada um com seu próprio `ads` —
    # suporta criar uma campanha com vários conjuntos/anúncios de uma vez
    # (pedido do usuário: duplicar Conjunto/Anúncio ao montar a campanha,
    # cada conjunto com seu próprio mapa/localização/público no front).
    # Sem essa chave, cai no formato antigo achatado (um conjunto + um
    # anúncio só, campos direto em `campanha`) — mantém compatibilidade
    # total com duplicate_adset_to_campaign, que só sabe montar esse formato.
    adsets_specs = campanha['adsets'].presence || [campanha]
    # CBO: o dinheiro é dividido pelo próprio Meta, então o conjunto não pode
    # mandar orçamento junto (a Meta usa o do conjunto e ignora o da campanha).
    if !adset_budget_shared
      # CBO é sempre diário: a Meta recusa `lifetime_budget` no conjunto quando
      # a campanha é CBO, então o vitalício do conjunto é descartado junto com
      # o diário.
      adsets_specs = adsets_specs.map { |spec| spec.except('daily_budget', 'lifetime_budget') }
      cbo_check = check_bid_amount_for_cbo(adsets_specs)
      # A campanha JÁ foi criada acima, então este erro também deixa órfã
      # (aí apareceu uma "ZZ CBO sem teto" parada na conta depois do teste).
      if cbo_check
        discard_orphan_campaign(campaign.data['id'])
        discard_orphan_lead_form(lead_form_id, campanha)
        return Result.new(success: false, error: cbo_check)
      end
    end

    created_adsets = []
    adsets_specs.each do |adset_spec|
      result = create_adset_with_ads(act: act, campaign_id: campaign.data['id'], adset_spec: adset_spec, lead_form_id: lead_form_id)
      unless result.success
        # Se qualquer etapa depois da campanha falhar, a campanha que a gente
        # acabou de criar fica PAUSED e órfã na conta do cliente — sujeira que
        # aparece na lista de campanhas e que ninguém sabe de onde veio (já
        # aconteceu: "não entendi essa campanha nova"). Não há gasto (PAUSED),
        # então deletar o que este mesmo fluxo criou é seguro.
        return result.tap do
          discard_orphan_campaign(campaign.data['id'])
          discard_orphan_lead_form(lead_form_id, campanha)
        end
      end

      created_adsets << result.data
    end

    Result.new(success: true, data: [{ 'body' => { 'success' => true, 'campaign_id' => campaign.data['id'], 'adsets' => created_adsets } }])
  end

  # Apaga a campanha criada por este mesmo fluxo após uma falha, sem deixar
  # isso virar erro novo — o erro real (o que importou pro usuário) já está
  # na Result que sobe. Falha ao apagar é só log.
  def discard_orphan_campaign(campaign_id)
    return if campaign_id.blank?

    result = delete("/#{campaign_id}")
    if result.success
      Rails.logger.info "Meta::AdsManagerService: campanha órfã #{campaign_id} removida após falha no fluxo"
    else
      Rails.logger.error "Meta::AdsManagerService: não consegui remover campanha órfã #{campaign_id} (#{result.error})"
    end
  end

  # Mesmo raciocínio da campanha órfã, pro formulário de cadastro: ele é
  # criado ANTES da campanha (o anúncio precisa do `lead_gen_form_id`), então
  # uma falha depois deixava o formulário_ACTIVE e sem campanha no Gerenciador
  # — aparecia na lista de formulários da Página como lixo. A Meta não aceita
  # DELETE em leadgen_forms, mas aceita arquivar (`status=ARCHIVED` no próprio
  # nó), que é o mesmo que o Gerenciador faz.
  def discard_orphan_lead_form(lead_form_id, campanha = {})
    return if lead_form_id.blank?

    result = post("/#{lead_form_id}", { status: 'ARCHIVED' }, page_token_for(campanha))
    if result.success
      Rails.logger.info "Meta::AdsManagerService: formulário de lead órfão #{lead_form_id} arquivado após falha no fluxo"
    else
      Rails.logger.error "Meta::AdsManagerService: não consegui arquivar formulário de lead órfão #{lead_form_id} (#{result.error})"
    end
  end

  # Cria um conjunto de anúncios + todos os seus anúncios (1 ou mais) dentro
  # de uma campanha já criada — usado pelo caminho novo (múltiplos
  # conjuntos) de create_campaign_full. `adset_spec['ads']` ausente (formato
  # antigo achatado) é tratado como se fosse um `ads` de um item só, com os
  # campos do anúncio no próprio `adset_spec`.
  def create_adset_with_ads(act:, campaign_id:, adset_spec:, lead_form_id:)
    targeting = resolve_targeting(act: act, targeting: adset_spec['targeting'] || {})
    return step_error(targeting, 'direcionamento (público/interesses)') unless targeting.success

    promoted_object = promoted_object_for(act: act, campanha: adset_spec)
    return step_error(promoted_object, 'objeto promovido (pixel/página)') unless promoted_object.success

    adset = post("/#{act}/adsets", {
                    name: adset_spec['adset_name'],
                    status: adset_spec['adset_status'].presence || 'PAUSED',
                    campaign_id: campaign_id,
                    # Descrição do conjunto aparece no Gerenciador de Anúncios e
                    # é o que o painel usa pra registrar em que página/conversa
                    # o conjunto roda.
                    description: adset_spec['description'],
                    daily_budget: adset_spec['daily_budget'],
                    # Orçamento vitalício: a Meta exige `end_time` junto, e
                    # nunca aceita vitalício junto com CBO.
                    lifetime_budget: adset_spec['lifetime_budget'],
                    end_time: adset_spec['end_time'],
                    optimization_goal: adset_spec['optimization_goal'],
                    bid_strategy: adset_spec['bid_strategy'],
                    # Com CBO a Meta troca a estratégia para
                    # LOWEST_COST_WITH_BID_CAP e aí o `bid_amount` passa a ser
                    # obrigatório (subcode 1815857). A Graph API exige o valor
                    # em CENTAVOS e como INTEIRO — mandar "15.00" volta
                    # "Param bid_amount must be an integer" (código 100).
                    bid_amount: bid_amount_for(adset_spec),
                    billing_event: 'IMPRESSIONS',
                    destination_type: destination_type_for(adset_spec),
                    promoted_object: promoted_object.data&.to_json,
                    targeting: targeting.data.to_json
                  }.merge(conversion_location_params(adset_spec))
                  .compact)
    return step_error(adset, 'conjunto de anúncios') unless adset.success

    ads_specs = adset_spec['ads'].presence || [adset_spec]
    created_ads = []
    ads_specs.each do |ad_spec|
      creative = build_creative(act: act, campanha: ad_spec, lead_form_id: lead_form_id)
      return step_error(creative, 'criativo') unless creative.success

      ad = create_ad_only(act: act, adset_id: adset.data['id'], creative_id: creative.data['id'], campanha: ad_spec)
      return ad unless ad.success

      created_ads << ad.data.first['body']
    end

    Result.new(success: true, data: { 'adset_id' => adset.data['id'], 'ads' => created_ads })
  end

  # Duplica um CONJUNTO DE ANÚNCIOS (com seu primeiro anúncio) pra dentro de
  # uma campanha JÁ EXISTENTE — inclusive uma de objetivo diferente. Mesma
  # lógica de duplicate_with_new_objective (lê público/criativo da origem e
  # recria do zero via create_adset_and_ad, nunca pelo endpoint `/copies` da
  # Graph API), só que o destino é uma campanha que já existe, não uma nova.
  def duplicate_adset_to_campaign(source_adset_id:, target_campaign_id:, ad_account_id:, new_optimization_goal: nil, overrides: {})
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    act = "act_#{ad_account_id}"

    target_campaign = get("/#{target_campaign_id}", fields: 'objective')
    return step_error(target_campaign, 'campanha de destino') unless target_campaign.success

    source = get(
      "/#{source_adset_id}",
      fields: 'name,daily_budget,targeting,ads.limit(1){name,creative{body,title,image_url,thumbnail_url,video_id,object_story_spec}}'
    )
    return step_error(source, 'conjunto de origem') unless source.success

    ad = source.data.dig('ads', 'data', 0)
    return Result.new(success: false, error: 'O conjunto de origem não tem anúncio pra copiar.') if ad.blank?

    creative = ad['creative'] || {}
    asset_url = resolve_creative_source_asset(creative)
    return Result.new(success: false, error: 'Não encontrei imagem nem vídeo no anúncio de origem pra reaproveitar.') if asset_url.blank?

    target_objective = target_campaign.data['objective']
    link = creative.dig('object_story_spec', 'link_data', 'link').presence
    campanha = {
      'objective' => target_objective,
      'optimization_goal' => new_optimization_goal.presence || DEFAULT_OPTIMIZATION_GOAL_BY_OBJECTIVE[target_objective],
      'adset_name' => overrides['adset_name'].presence || source.data['name'],
      'adset_status' => 'PAUSED',
      'daily_budget' => overrides['daily_budget'].presence || source.data['daily_budget'],
      'bid_strategy' => overrides['bid_strategy'].presence || 'LOWEST_COST_WITHOUT_CAP',
      'ad_name' => overrides['ad_name'].presence || ad['name'],
      'ad_status' => 'PAUSED',
      'title' => overrides['title'].presence || creative['title'],
      'body' => overrides['body'].presence || creative['body'],
      'asset_url' => asset_url,
      'link' => overrides['link'].presence || link,
      'targeting' => source.data['targeting'] || {}
    }.merge(adset_level_overrides(overrides)).compact

    lead_form_id = nil
    if lead_flow?(campanha)
      lead_form = create_lead_form(campanha: campanha)
      return step_error(lead_form, 'formulário de cadastro') unless lead_form.success

      lead_form_id = lead_form.data['id']
    end

    create_adset_and_ad(act: act, campaign_id: target_campaign_id, campanha: campanha, lead_form_id: lead_form_id)
      .tap do |result|
        discard_orphan_lead_form(lead_form_id, campanha) unless result.success
      end
  end

  # Duplica só o ANÚNCIO (criativo) pra dentro de um CONJUNTO já existente —
  # mesmo raciocínio, mas sem mexer em campanha/conjunto/público: o
  # direcionamento já é o do conjunto de destino, só o criativo é novo.
  def duplicate_ad_to_adset(source_ad_id:, target_adset_id:, ad_account_id:, overrides: {})
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    act = "act_#{ad_account_id}"

    target_adset = get("/#{target_adset_id}", fields: 'campaign_id,optimization_goal')
    return step_error(target_adset, 'conjunto de destino') unless target_adset.success

    target_campaign = get("/#{target_adset.data['campaign_id']}", fields: 'objective')
    return step_error(target_campaign, 'campanha de destino') unless target_campaign.success

    source_ad = get("/#{source_ad_id}", fields: 'name,creative{body,title,image_url,thumbnail_url,video_id,object_story_spec}')
    return step_error(source_ad, 'anúncio de origem') unless source_ad.success

    creative_src = source_ad.data['creative'] || {}
    asset_url = resolve_creative_source_asset(creative_src)
    return Result.new(success: false, error: 'Não encontrei imagem nem vídeo no anúncio de origem pra reaproveitar.') if asset_url.blank?

    campanha = {
      'objective' => target_campaign.data['objective'],
      'optimization_goal' => target_adset.data['optimization_goal'],
      'ad_name' => overrides['ad_name'].presence || "#{source_ad.data['name']} - Cópia",
      'ad_status' => 'PAUSED',
      'title' => overrides['title'].presence || creative_src['title'],
      'body' => overrides['body'].presence || creative_src['body'],
      'asset_url' => asset_url,
      'link' => overrides['link'].presence || creative_src.dig('object_story_spec', 'link_data', 'link').presence
    }.compact

    lead_form_id = nil
    if lead_flow?(campanha)
      lead_form = create_lead_form(campanha: campanha)
      return step_error(lead_form, 'formulário de cadastro') unless lead_form.success

      lead_form_id = lead_form.data['id']
    end

    creative = build_creative(act: act, campanha: campanha, lead_form_id: lead_form_id)
    unless creative.success
      discard_orphan_lead_form(lead_form_id, campanha)
      return step_error(creative, 'criativo')
    end

    create_ad_only(act: act, adset_id: target_adset_id, creative_id: creative.data['id'], campanha: campanha)
      .tap { |result| discard_orphan_lead_form(lead_form_id, campanha) unless result.success }
  end

  # --- Aba "Criação Meta" (Marketing) — formulários de lead avulsos e
  # públicos, independentes da criação de campanha. `create_lead_form`
  # (privado, mais abaixo) continua existindo só pro fluxo automático de
  # campanha com objetivo de leads; este é o formulário que o usuário monta
  # à mão, com as próprias perguntas/política de privacidade.
  #
  # Formulários de lead pertencem a uma PÁGINA (não à conta de anúncio) — o
  # picker "BM > Conta" das outras abas não serve aqui. `pages_for_business`
  # espelha `ad_accounts` (owned + client), e `page_access_token_for` busca
  # o token de PÁGINA sob demanda via Graph API (a Graph API exige
  # especificamente esse token pra /leadgen_forms — o user_access_token dá
  # "(#190) This method must be called with a Page Access Token" mesmo
  # tendo a permissão). Isso evita depender só da única linha em
  # Channel::FacebookPage: qualquer Página que a BM escolhida enxergue pode
  # ser usada, não só a que já está conectada como canal de mensagens.
  # `instagram_business_account` entra nos fields porque é por ela que a Meta
  # associa um perfil profissional a uma Página — é o que dá a lista de
  # contas de Instagram (e os Reels) de uma BM.
  def pages_for_business(business_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    fields = 'id,name,instagram_business_account{id,username,name}'
    owned = get("/#{business_id}/owned_pages", fields: fields)
    return owned unless owned.success

    client = get("/#{business_id}/client_pages", fields: fields)
    return client unless client.success

    Result.new(success: true, data: (owned.data + client.data).uniq { |p| p['id'] })
  end

  def page_access_token_for(page_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    result = get("/#{page_id}", fields: 'access_token')
    return result unless result.success
    return Result.new(success: false, error: 'Não consegui obter o token desta Página — confira se a conta conectada é admin dela.') if result.data['access_token'].blank?

    Result.new(success: true, data: result.data['access_token'])
  end

  def leadgen_forms(page_id:)
    token = resolve_page_token(page_id)
    return token unless token.success

    get("/#{page_id}/leadgen_forms", { fields: 'id,name,status,leads_count,created_time' }, token.data)
  end

  def leadgen_form_detail(page_id:, form_id:)
    token = resolve_page_token(page_id)
    return token unless token.success

    # A Graph API não devolve `privacy_policy` como campo de leitura direto
    # (só de escrita na criação) — quem volta é `legal_content.privacy_policy`.
    get(
      "/#{form_id}",
      { fields: 'id,name,status,questions,legal_content{privacy_policy},context_card,thank_you_page,follow_up_action_url' },
      token.data
    )
  end

  def update_leadgen_form_status(page_id:, form_id:, status:)
    token = resolve_page_token(page_id)
    return token unless token.success

    post("/#{form_id}", { status: status }, token.data)
  end

  # questions: array de {type:} — pra CUSTOM, também {key:, label:} e,
  # quando for múltipla escolha, {options: [{key:, value:}, ...]}.
  # privacy_policy_url: a Graph API exige um dos dois (essa ou
  # legal_content_id, mais avançado) pra criar qualquer formulário — não dá
  # pra tornar opcional de verdade; cai pro site da empresa quando em
  # branco, então a pessoa não PRECISA digitar nada, mas a Meta sempre
  # recebe uma URL real.
  def create_leadgen_form(
    page_id:, name:, questions:,
    privacy_policy_url: nil, privacy_policy_link_text: 'Política de Privacidade',
    greeting_title: nil, greeting_content: nil, greeting_button_text: 'Continuar',
    thank_you_title: nil, thank_you_body: nil, thank_you_button_type: nil,
    thank_you_button_text: nil, thank_you_website_url: nil
  )
    return Result.new(success: false, error: 'Informe ao menos uma pergunta.') if questions.blank?

    token = resolve_page_token(page_id)
    return token unless token.success

    body = {
      name: name,
      questions: questions.to_json,
      privacy_policy: {
        url: privacy_policy_url.presence || 'https://www.anunciocertobr.com.br/privacidade',
        link_text: privacy_policy_link_text.presence || 'Política de Privacidade'
      }.to_json,
      follow_up_action_url: thank_you_website_url.presence || "https://www.facebook.com/#{page_id}"
    }

    if greeting_title.present?
      body[:context_card] = {
        title: greeting_title,
        content: Array(greeting_content.presence || []),
        button_text: greeting_button_text.presence || 'Continuar',
        style: 'PARAGRAPH_STYLE'
      }.to_json
    end

    if thank_you_title.present?
      thank_you = {
        title: thank_you_title,
        body: thank_you_body.presence || 'Obrigado! Entraremos em contato em breve.',
        button_type: thank_you_button_type.presence || 'VIEW_WEBSITE',
        button_text: thank_you_button_text.presence || 'Fechar'
      }
      thank_you[:website_url] = thank_you_website_url if thank_you_website_url.present?
      body[:thank_you_page] = thank_you.to_json
    end

    post("/#{page_id}/leadgen_forms", body, token.data)
  end

  # A Graph API não tem "editar" um formulário depois de criado (nome,
  # perguntas etc. são imutáveis pra sempre — só o status ACTIVE/ARCHIVED
  # pode mudar, via update_leadgen_form_status). "Duplicar" é o caminho real
  # pra algo parecido com editar: busca os dados completos do formulário de
  # origem e cria um novo (na mesma Página ou em outra) com esses dados +
  # o que vier em `overrides`.
  def duplicate_leadgen_form(source_page_id:, form_id:, target_page_id:, overrides: {})
    detail = leadgen_form_detail(page_id: source_page_id, form_id: form_id)
    return detail unless detail.success

    source = detail.data
    privacy = source.dig('legal_content', 'privacy_policy') || {}
    context_card = source['context_card']
    thank_you = source['thank_you_page']
    # A leitura devolve `id` (sempre) e `key`/`label` (pra TODO tipo, mesmo
    # os padrão) em cada pergunta — a escrita rejeita `id` sempre
    # ("Invalid keys") e rejeita `label` em perguntas que não sejam CUSTOM
    # ("Rótulo especificado para perguntas não personalizadas"). Só CUSTOM
    # pode (e precisa) levar key/label/options de volta.
    source_questions = (source['questions'] || []).map do |q|
      q['type'] == 'CUSTOM' ? q.slice('type', 'key', 'label', 'options') : q.slice('type')
    end

    create_leadgen_form(
      page_id: target_page_id,
      name: overrides[:name].presence || "#{source['name']} - Cópia",
      questions: overrides[:questions].presence || source_questions,
      privacy_policy_url: overrides[:privacy_policy_url].presence || privacy['url'],
      privacy_policy_link_text: overrides[:privacy_policy_link_text].presence || privacy['link_text'],
      greeting_title: overrides[:greeting_title].presence || context_card&.dig('title'),
      greeting_content: overrides[:greeting_content].presence || context_card&.dig('content'),
      greeting_button_text: overrides[:greeting_button_text].presence || context_card&.dig('button_text'),
      thank_you_title: overrides[:thank_you_title].presence || thank_you&.dig('title'),
      thank_you_body: overrides[:thank_you_body].presence || thank_you&.dig('body'),
      thank_you_button_type: overrides[:thank_you_button_type].presence || thank_you&.dig('button_type'),
      thank_you_button_text: overrides[:thank_you_button_text].presence || thank_you&.dig('button_text'),
      thank_you_website_url: overrides[:thank_you_website_url].presence || thank_you&.dig('website_url')
    )
  end

  # --- Públicos (Custom Audiences) ---

  def custom_audiences(ad_account_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    get(
      "/act_#{id}/customaudiences",
      fields: 'id,name,subtype,description,approximate_count_lower_bound,approximate_count_upper_bound,delivery_status,operation_status',
      limit: 200
    )
  end

  def pixels(ad_account_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    get("/act_#{id}/adspixels", fields: 'id,name')
  end

  # Lista as Páginas que podem criar públicos de engajamento numa conta de
  # anúncio (Facebook Page / Instagram) e as contas de Instagram da mesma
  # origem. Segue a mesma owned_pages + client_pages de pages_for_business.
  #
  # business_id: a BM que está selecionada na UI. É preferível a resolver
  # pelo `owner` da conta porque conta de anúncio comprada por terceiro NÃO
  # tem o dono do gerenciador: o `owner` de uma conta cliente é outra BM (ou
  # a própria pessoa), e as Páginas que o usuário realmente administra estão
  # na BM da UI — no caso real que motivou isso, o `owner` apontava para uma
  # BM diferente e a lista vinha sem as Páginas da conta.
  def pages_for_ad_account(ad_account_id:, business_id: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    business_id = business_id.presence || owning_business_of_ad_account(ad_account_id)
    if business_id.blank?
      return Result.new(
        success: false,
        error: 'Não foi possível localizar a Business Manager desta conta de anúncio. Selecione a BM no topo da tela.'
      )
    end

    pages_for_business(business_id: business_id)
  end

  # Contas de Instagram (perfil profissional) ligadas às Páginas de uma BM —
  # é o `ig_user_id` que o público de engajamento do Instagram e a listagem de
  # Reels usam. Páginas sem perfil profissional simplesmente não entram.
  def instagram_accounts_for_business(business_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    pages = pages_for_business(business_id: business_id)
    return pages unless pages.success

    accounts = pages.data.filter_map do |page|
      ig = page['instagram_business_account']
      next if ig.blank? || ig['id'].blank?

      {
        'id' => ig['id'],
        'username' => ig['username'],
        'name' => ig['name'].presence || ig['username'],
        'page_id' => page['id'],
        'page_name' => page['name']
      }
    end.uniq { |ig| ig['id'] }

    Result.new(success: true, data: accounts)
  end

  # Lista os vídeos disponíveis pra criar um público de vídeo, com as
  # informações que o Gerenciador de Anúncios mostra na hora de escolher.
  # A escolha de origem segue as três abas do Ad Manager:
  #
  #   page    -> GET /{page_id}/videos  (Facebook da Página)
  #   ig      -> GET /{ig_user_id}/media filtrando media_type=VIDEO
  #               (Reels do perfil profissional)
  #   conta   -> GET /me/videos (Facebook da conta conectada)
  #
  # Os IDs que a Audience exige no `video_id` são exatamente o id do vídeo do
  # Facebook, o id da mídia do Reels ou o id do vídeo da própria conta.
  def videos_by_source(source:, source_id: nil, limit: 50)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    case source.to_s
    when 'page'
      return Result.new(success: false, error: 'Escolha a Página do Facebook de onde puxar o vídeo.') if source_id.blank?

      page_videos(page_id: source_id, limit: limit)
    when 'ig'
      return Result.new(success: false, error: 'Escolha a conta de Instagram de onde puxar o vídeo.') if source_id.blank?

      instagram_reels(ig_user_id: source_id, limit: limit)
    when 'conta'
      account_videos(limit: limit)
    else
      Result.new(success: false, error: 'Origem de vídeo inválida.')
    end
  end

  # Facebook: `/{page_id}/videos`. Validado na API real — `reactions` e
  # `comments_count` NÃO existem nessa aresta e derrubam a requisição
  # inteira, então a lista de campos aqui é a que passou no teste.
  def page_videos(page_id:, limit: 50)
    result = get(
      "/#{page_id}/videos",
      fields: 'id,title,description,created_time,length,views_count,permalink_url,thumbnails{url,height,width}',
      limit: limit
    )
    return result unless result.success

    page = get("/#{page_id}", fields: 'name')
    page_name = page.success ? page.data['name'] : nil

    Result.new(
      success: true,
      data: result.data.map { |v| normalize_video(v, source: 'page', source_name: page_name) }
    )
  end

  # Instagram: `/{ig_user_id}/media` traz as mídias do perfil profissional
  # (Reels, posts, carrossel); filtramos por media_type=VIDEO que é o que
  # serve de origem de público. O `media_product_type` distingue REELS de
  # feed, e não existe aresta `/reels` na API.
  def instagram_reels(ig_user_id:, limit: 50)
    result = get(
      "/#{ig_user_id}/media",
      fields: 'id,caption,media_type,media_product_type,permalink,timestamp,like_count,comments_count,thumbnail_url',
      limit: limit
    )
    return result unless result.success

    Result.new(
      success: true,
      data: result.data.select { |m| m['media_type'].to_s.casecmp('video').zero? }
             .map { |m| normalize_video(m, source: 'ig', source_name: nil) }
    )
  end

  # Conta do Facebook conectada: `GET /me/videos` é a timeline da conta.
  def account_videos(limit: 50)
    result = get(
      '/me/videos',
      fields: 'id,title,description,created_time,length,views_count,permalink_url,thumbnails{url,height,width}',
      limit: limit
    )
    return result unless result.success

    Result.new(success: true, data: result.data.map { |v| normalize_video(v, source: 'conta', source_name: nil) })
  end

  # Normaliza vídeo de Página e vídeo de Instagram no mesmo formato, com a
  # origem e as informações que a lista da UI mostra. Título vazio é comum
  # (vídeo do Facebook sem descrição e Reels só com legenda), então a UI
  # cai pra legenda/data em vez de mostrar linha em branco.
  def normalize_video(video, source:, source_name:)
    caption = video['caption'].presence || video['description'].presence
    created = video['created_time'].presence || video['timestamp'].presence

    {
      'id' => video['id'],
      'title' => video['title'].presence || caption,
      'description' => video['description'].presence,
      'caption' => caption,
      'source' => source,
      'source_name' => source_name,
      'media_type' => video['media_product_type'].presence || video['media_type'].presence,
      'created_time' => created,
      'length' => video['length'],
      'views_count' => video['views_count'],
      'like_count' => video['like_count'],
      'comments_count' => video['comments_count'],
      'permalink_url' => video['permalink_url'].presence || video['permalink'].presence,
      'thumbnail_url' => video.dig('thumbnails', 'data', 0, 'url').presence || video['thumbnail_url']
    }
  end

  # BM dona de uma conta de anúncio. `?fields=owner` devolve `owner` como
  # STRING (o id), não como objeto — usar dig('owner', 'id') estoura
  # TypeError e derrubava a listagem de Páginas com 500.
  def owning_business_of_ad_account(ad_account_id)
    id = ad_account_id.to_s.delete_prefix('act_')
    account = get("/act_#{id}", fields: 'owner')
    return nil unless account.success

    owner = account.data['owner']
    owner.is_a?(Hash) ? owner['id'] : owner
  end

  # Perfil profissional do Instagram ligado a uma Página — é o `ig_user_id`
  # que o público de engajamento do Instagram usa como event_source. Pode
  # falhar (página sem perfil profissional ou sem permissão), e nesse caso a
  # UI deixa o usuário digitar o id na mão.
  def instagram_account_for_page(page_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    result = get("/#{page_id}", fields: 'instagram_business_account{id,username,name}')
    return result unless result.success

    ig = result.data['instagram_business_account']
    return Result.new(success: false, error: 'Esta Página não tem perfil profissional do Instagram vinculado.') if ig.blank?

    Result.new(success: true, data: { 'id' => ig['id'], 'name' => ig['username'].presence || ig['name'].presence || ig['id'] })
  end

  # `fields` de um custom audience varia MUITO por subtype, e a lista de campos
  # LEGÍVEIS é menor do que a de escrita (não existem video_id/page_id/app_id
  # na leitura — o que volta é rule/video_group_ids/data_source*). Pedir um
  # campo inexistente derruba a leitura inteira com #100 "Tried accessing
  # nonexisting field", então tentamos a lista completa e caímos pra um mínimo
  # que ainda tem o `rule` (é dele que sai o tipo real do público) se a Meta
  # recusar.
  # Cada campo desta lista foi testado um a um contra a Graph API real
  # (GET /{id}?fields=X): a API responde 400 "(#100) Tried accessing
  # nonexisting field" para um único campo desconhecido e ABORTA a leitura
  # inteira. Foi por isso que duplicar na mesma conta não preenchia o
  # formulário: bastava um destes campos não existir pro público inteiro
  # falhar — e o fallback falhava pelo mesmo motivo. Não voltar a colocar
  # campo aqui "porque parece que existe": `prefill`, `origin_audience_id`,
  # `video_group_ids`, `facebook_page_id`, `creation_params`, `event_sources`,
  # `video_id`, `app_id`, `ig_user_id` e `page_id` foram todos rejeitados.
  # O id da origem do vídeo/página/app NÃO é legível — vem dentro da `rule`.
  AUDIENCE_DETAIL_FIELDS = %w[
    id name subtype description retention_days lookalike_spec pixel_id
    rule data_source data_source_types
    included_custom_audiences excluded_custom_audiences
    account_id approximate_count_lower_bound delivery_status
  ].freeze

  AUDIENCE_DETAIL_FALLBACK_FIELDS =
    'id,name,subtype,description,retention_days,lookalike_spec,rule,pixel_id'.freeze

  # Usado pelo "Duplicar público" pra preencher o formulário com os dados REAIS
  # do público de origem (tipo, pixel/página/app/vídeo de origem, retenção,
  # URL, lookalike_spec) — antes só voltavam nome/descrição/retention/lookalike,
  # então qualquer público que não fosse WEBSITE/LOOKALIKE/CUSTOM (ex.: um de
  # vídeo) caía no fallback "Site (Pixel)" e ficava travado pedindo pixel.
  def audience_detail(audience_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    result = get("/#{audience_id}", fields: AUDIENCE_DETAIL_FIELDS.join(','))
    return result if result.success

    get("/#{audience_id}", fields: AUDIENCE_DETAIL_FALLBACK_FIELDS)
  end

  # Nome do público de origem de um semelhante, pra dar pra pré-selecionar na
  # conta de destino o público com o mesmo nome ao duplicar.
  def audience_name(audience_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    get("/#{audience_id}", fields: 'id,name')
  end

  # Exclui um público. A exclusão é por NÓ (`DELETE /{audience_id}`) e não pela
  # aresta da conta: `DELETE /act_{id}/customaudiences?audience_ids=[...]`
  # responde "Unsupported delete request" mesmo com a conta e o token
  # corretos — a aresta só aceita leitura. Um público por chamada, sem
  # lote, pra nunca apagar mais do que a tela pediu.
  #
  # A exclusão é definitiva e não tem volta na Graph API: audiences de
  # público salvos/lookalike somem e o histórico de veiculação do conjunto
  # perde a referência. Por isso o nome é lido antes e devolvido no erro,
  # pra UI poder nomear o que se está apagando.
  def delete_audience(audience_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = audience_id.to_s.delete_prefix('act_')
    return Result.new(success: false, error: 'Informe o público que deseja excluir.') if id.blank?

    name = get("/#{id}", fields: 'id,name,subtype,lookalike_spec')
    audience = name.success ? name.data : nil
    unless audience
      return Result.new(success: false, error: 'Público não encontrado na conta de anúncio (ou sem permissão para ele).')
    end

    if audience['lookalike_spec'].present?
      return Result.new(
        success: false,
        error: 'Público semelhante não pode ser excluído pela API da Meta. Ele existe em função do público de origem.'
      )
    end

    result = delete("/#{id}")
    return result unless result.success

    Result.new(
      success: true,
      data: { id: id, name: audience['name'], subtype: audience['subtype'], deleted: true }
    )
  end

  # Monta a regra (rule) de um público a partir de uma fonte de evento. É o
  # mesmo formato pra site/pixel, página, Instagram e app — o que muda é o
  # `type` do event_source e o filtro do evento.
  #
  # max_days existe porque o teto de retenção NÃO é o mesmo pra todos os tipos:
  # público de site/pixel vai até 180 dias, enquanto engajamento, Instagram,
  # app e vídeo vão até 365. A Graph API rejeita acima do limite com erro
  # genérico de parâmetro inválido, então cortamos aqui.
  def audience_rule(event_source_type:, event_source_id:, retention_days:, event_value: nil, url_contains: nil, max_days: 365)
    filter = if url_contains.present?
               { field: 'url', operator: 'i_contains', value: url_contains }
             else
               { field: 'event', operator: 'eq', value: event_value.presence || 'PageView' }
             end

    {
      inclusions: {
        operator: 'or',
        rules: [
          {
            event_sources: [{ id: event_source_id.to_s, type: event_source_type }],
            retention_seconds: retention_days.to_i.clamp(1, max_days) * 86_400,
            filter: { operator: 'and', filters: [filter] }
          }
        ]
      }
    }
  end

  # retention_days: janela de quem entra no público (1-180, o teto dos públicos
  # de site/pixel na Graph API). Sem url_contains, usa todo mundo que visitou
  # o site (PageView) em vez de uma página específica.
  def create_website_audience(ad_account_id:, name:, pixel_id:, retention_days:, url_contains: nil, description: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    post("/act_#{id}/customaudiences", {
      name: name,
      description: description,
      rule: audience_rule(
        event_source_type: 'pixel',
        event_source_id: pixel_id,
        retention_days: retention_days,
        event_value: 'PageView',
        url_contains: url_contains,
        max_days: 180
      ).to_json,
      prefill: 1
    }.compact)
  end

  # Público de engajamento com a Facebook Page — "interagiu com a página"
  # (page_engaged), "interagiu com posts" (page_post_interaction), "abriu o
  # formulário de lead" (lead_form_open) ou "abriu o anúncio de experience"
  # (instant_experience_open). Desde set/2018 a Graph API NÃO aceita `subtype`
  # nesses públicos (a exceção é vídeo): a identidade vem da rule.
  def create_engagement_audience(ad_account_id:, name:, page_id:, retention_days:, event_value: 'page_engaged', description: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    post("/act_#{id}/customaudiences", {
      name: name,
      description: description,
      rule: audience_rule(
        event_source_type: 'page',
        event_source_id: page_id,
        retention_days: retention_days,
        event_value: event_value
      ).to_json,
      prefill: 1
    }.compact)
  end

  # Público do Instagram: o event_source é o ig_user_id (tipo 'page') e o
  # evento ig_business_profile_engaged. É o mesmo formato do de engajamento,
  # só que a fonte é o perfil profissional em vez da Página.
  def create_instagram_audience(ad_account_id:, name:, ig_user_id:, retention_days:, event_value: 'ig_business_profile_engaged', description: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    post("/act_#{id}/customaudiences", {
      name: name,
      description: description,
      rule: audience_rule(
        event_source_type: 'page',
        event_source_id: ig_user_id,
        retention_days: retention_days,
        event_value: event_value
      ).to_json,
      prefill: 1
    }.compact)
  end

  # Público de app: event_source tipo 'app' com o app_id, e o evento do app
  # ('any' = qualquer evento, ou o nome do evento, ex.: 'Purchase').
  def create_app_audience(ad_account_id:, name:, app_id:, retention_days:, event_name: 'any', description: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    post("/act_#{id}/customaudiences", {
      name: name,
      description: description,
      rule: audience_rule(
        event_source_type: 'app',
        event_source_id: app_id,
        retention_days: retention_days,
        event_value: event_name.presence || 'any'
      ).to_json,
      prefill: 1
    }.compact)
  end

  # Público de vídeo: aqui a Graph API aceita sim o `subtype` (é a exceção
  # documentada dos públicos de engajamento) — video_id + retenção. O vídeo
  # precisa pertencer à conta (ou a uma Página da conta).
  def create_video_audience(ad_account_id:, name:, video_id:, retention_days:, description: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    post("/act_#{id}/customaudiences", {
      name: name,
      subtype: 'VIDEO',
      description: description,
      video_id: video_id,
      retention_days: retention_days.to_i.clamp(1, 365)
    }.compact)
  end

  # ratio: 0.01 a 0.20 (1% a 20% do país, granularidade mínima da própria
  # Graph API pra Lookalike). A origem é OU um público que já existe na
  # própria conta (origin_audience_id — serve pra qualquer tipo: site, vídeo,
  # engajamento, Instagram, app, lista de clientes e também público salvo),
  # OU uma source_spec, que é como se faz "semelhante de site/engajamento/
  # app" direto da fonte, sem precisar antes criar o público-semente.
  def create_lookalike_audience(ad_account_id:, name:, country:, ratio:, origin_audience_id: nil, source_spec: nil, lookalike_type: 'similarity')
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
    if origin_audience_id.blank? && source_spec.blank?
      return Result.new(success: false, error: 'Escolha o público de origem do público semelhante.')
    end

    id = ad_account_id.to_s.delete_prefix('act_')
    spec = { type: lookalike_type.presence || 'similarity', country: country.to_s.upcase.presence || 'BR', ratio: ratio.to_f.clamp(0.01, 0.20) }
    spec[:source_spec] = source_spec if source_spec.present?

    post("/act_#{id}/customaudiences", {
      name: name,
      subtype: 'LOOKALIKE',
      origin_audience_id: origin_audience_id.presence,
      lookalike_spec: spec.to_json
    }.compact)
  end

  # Cria só o "balde" vazio — a população de fato (hash dos contatos) é um
  # passo separado, add_contacts_to_audience, porque a Graph API já trata
  # como duas chamadas diferentes (POST /customaudiences depois POST
  # /{id}/users) e a UI pede o público criado antes de deixar escolher quem
  # entra nele.
  def create_customer_list_audience(ad_account_id:, name:, description: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    post("/act_#{id}/customaudiences", {
      name: name,
      subtype: 'CUSTOM',
      description: description,
      customer_file_source: 'USER_PROVIDED_ONLY'
    }.compact)
  end

  # contacts: array de {email:, phone:}. Email/telefone só saem daqui como
  # SHA-256 do valor normalizado (email minúsculo/sem espaços, telefone só
  # dígitos) — exatamente o que a Graph API exige pra Custom Audience por
  # lista de clientes; nenhum dado em claro chega na Meta.
  def add_contacts_to_audience(audience_id:, contacts:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
    return Result.new(success: false, error: 'Nenhum contato com email ou telefone válido.') if contacts.blank?

    rows = contacts.filter_map do |c|
      email_hash = hash_pii(c[:email]&.strip&.downcase)
      phone_hash = hash_pii(c[:phone].to_s.gsub(/\D/, ''))
      [email_hash || '', phone_hash || ''] if email_hash || phone_hash
    end
    return Result.new(success: false, error: 'Nenhum contato com email ou telefone válido.') if rows.empty?

    results = rows.each_slice(10_000).map do |batch|
      post("/#{audience_id}/users", payload: { schema: %w[EMAIL PHONE], data: batch }.to_json)
    end

    failed = results.find { |r| !r.success }
    return failed if failed

    Result.new(success: true, data: { 'uploaded' => rows.size })
  end

  # --- Direcionamento Detalhado (interesses, comportamentos, dados demográficos) ---

  TARGETING_CLASSES = %w[interests behaviors demographics].freeze

  def search_targeting(query:, category:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
    return Result.new(success: false, error: 'Categoria de direcionamento inválida.') unless TARGETING_CLASSES.include?(category)

    if category == 'interests'
      # type=adinterest é o mesmo endpoint que a busca de interesses do
      # Gerenciador de Anúncios usa — filtra por texto de verdade e já
      # devolve tamanho de público.
      get('/search', { type: 'adinterest', q: query, limit: 25 })
    else
      # type=adTargetingCategory (behaviors/demographics) IGNORA `q` — é um
      # endpoint de listagem por classe, não de busca por texto (confirmado
      # testando: "compra" e "casado" devolvem a mesma lista genérica de
      # sempre). Como cada classe tem no máximo algumas centenas de itens,
      # busca a lista inteira uma vez e filtra por substring aqui.
      result = get('/search', { type: 'adTargetingCategory', class: category, limit: 1000 })
      return result unless result.success

      filtered = result.data.select { |item| item['name'].to_s.downcase.include?(query.to_s.downcase) }
      Result.new(success: true, data: filtered.first(25))
    end
  end

  # Interesses relacionados aos já escolhidos — mesmo recurso do "Sugestões"
  # do Gerenciador de Anúncios da própria Meta.
  def targeting_suggestions(interest_names:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
    return Result.new(success: true, data: []) if interest_names.blank?

    get('/search', type: 'adinterestsuggestion', interest_list: interest_names.to_json, limit: 25)
  end

  # targeting: hash já no formato flexible_spec/exclusions/geo_locations/
  # age_min/age_max/genders que a Graph API espera — montado no frontend a
  # partir dos itens escolhidos (ver TargetingBuilder.tsx).
  def reach_estimate(ad_account_id:, targeting:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    result = get("/act_#{id}/delivery_estimate", targeting_spec: targeting.to_json, optimization_goal: 'REACH')
    return result unless result.success

    Result.new(success: true, data: result.data.is_a?(Array) ? (result.data.first || {}) : result.data)
  end

  # "Saved Audience" — o direcionamento detalhado em si não é um objeto que
  # a Graph API guarda sozinho (ao contrário de Custom Audience); pra ficar
  # de fato salvo e reutilizável em campanhas futuras, precisa virar um
  # Saved Audience nomeado.
  def create_saved_audience(ad_account_id:, name:, targeting:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    post("/act_#{id}/saved_audiences", { name: name, targeting: targeting.to_json })
  end

  # Lista os públicos salvos (direcionamento completo — geo/idade/gênero/
  # interesses) já criados nesta conta, pra exibir e permitir duplicar pra
  # outra conta (ver duplicate_saved_audience).
  def saved_audiences(ad_account_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    # `approximate_count` NÃO é um campo válido do edge /saved_audiences —
    # a Graph API responde 400 (#100) "Tried accessing nonexisting field"
    # quando a conta tem público salvo, derrubando a lista inteira. Usamos
    # os bounds (válidos), que o front mapeia pra exibir o tamanho.
    get("/act_#{id}/saved_audiences", fields: 'id,name,description,targeting,approximate_count_lower_bound,approximate_count_upper_bound', limit: 200)
  end

  # Recria, do zero, um público salvo de uma conta em OUTRA conta — a Graph
  # API não tem um endpoint de "copiar" público salvo entre contas (só
  # dentro da mesma conta via /copies), então lê a definição completa da
  # origem e reenvia como criação nova no destino.
  def duplicate_saved_audience(source_audience_id:, target_ad_account_id:, overrides: {})
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    source = get("/#{source_audience_id}", fields: 'name,targeting')
    return step_error(source, 'público salvo de origem') unless source.success

    create_saved_audience(
      ad_account_id: target_ad_account_id,
      name: overrides[:name].presence || "#{source.data['name']} - Cópia",
      targeting: overrides[:targeting].presence || source.data['targeting']
    )
  end

  private

  # Página da campanha. Antes era sempre `Channel::FacebookPage.first` — a
  # única página do banco —, o que impedia rodar a mesma estrutura de
  # campanha em páginas diferentes. Agora a campanha/conjunto pode trazer seu
  # próprio `page_id` (o seletor do painel manda o da página escolhida) e, sem
  # ele, cai na página conectada para não mudar o comportamento de quem não
  # escolhe nada.
  def page_id_for(campanha)
    campanha['page_id'].presence || @page&.page_id
  end

  # Token da página escolhida. A página do banco já tem o token guardado (nada
  # de ida à Graph API); qualquer outra tem o token buscado sob demanda, que é
  # o mesmo caminho que a aba de Formulários já usava.
  def page_token_for(campanha)
    page_id = page_id_for(campanha)
    return @page&.page_access_token if page_id.present? && page_id == @page&.page_id
    return nil if page_id.blank?

    resolve_page_token(page_id).data
  end

  # Instagram da página escolhida — o `promoted_object` de "visita ao perfil"
  # precisa do `instagram_actor_id` DA PÁGINA QUE ESTÁ RODANDO, não o da página
  # do banco. Só busca na Graph API quando a escolha é outra página, porque é
  # essa consulta que custa uma ida ao servidor.
  def instagram_id_for(campanha)
    page_id = page_id_for(campanha)
    return @page&.instagram_id if page_id.blank? || page_id == @page&.page_id

    result = get("/#{page_id}", fields: 'instagram_business_account{id}')
    result.success ? result.data.dig('instagram_business_account', 'id') : nil
  end

  def resolve_page_token(page_id)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?
    return Result.new(success: false, error: 'Selecione uma Página.') if page_id.blank?

    page_access_token_for(page_id: page_id)
  end

  # Resume o `targeting` de uma lista de conjuntos de anúncio num único
  # público "representativo" pra pré-preencher a conta em Metas de
  # Clientes: idade mínima/máxima como a ENVOLTÓRIA de tudo que já foi
  # usado (menor idade mínima, maior idade máxima já configuradas —
  # "de todo o histórico" pede a faixa mais ampla já alcançada, não a mais
  # comum), gênero como união (só vira "male"/"female" se a conta NUNCA
  # tiver targetizado o outro gênero; qualquer mistura vira "all"), e
  # localizações como o conjunto (sem repetição) de cidades/regiões/países
  # já usados, na ordem em que aparecem.
  def summarize_targeting(adsets)
    age_mins = []
    age_maxes = []
    genders = Set.new
    locations = {}

    adsets.each do |adset|
      targeting = adset['targeting'] || {}
      age_mins << targeting['age_min'] if targeting['age_min'].present?
      age_maxes << targeting['age_max'] if targeting['age_max'].present?
      Array(targeting['genders']).each { |g| genders << g }

      geo = targeting['geo_locations'] || {}
      Array(geo['cities']).each { |c| locations[c['name']] ||= c['radius'] if c['name'].present? }
      Array(geo['regions']).each { |r| locations[r['name']] ||= nil if r['name'].present? }
      Array(geo['countries']).each { |code| locations[code] ||= nil if code.present? }
    end

    gender = if genders.empty? || (genders.include?(1) && genders.include?(2))
               'all'
             elsif genders.include?(1)
               'male'
             else
               'female'
             end

    {
      'age_min' => age_mins.min,
      'age_max' => age_maxes.max,
      'gender' => gender,
      'locations' => locations.first(20).map { |name, radius| { 'name' => name, 'radius' => radius } }
    }
  end

  # Monta a árvore campanha > conjunto > anúncio de #account_history_summary
  # já com métricas agregadas (soma dos anúncios filhos pra cima) em cada
  # nível, pra Metas de Clientes não precisar re-somar nada no front.
  def build_campaign_node(campaign, insights_by_ad_id)
    adsets = Array(campaign.dig('adsets', 'data')).map { |a| build_adset_node(a, insights_by_ad_id) }

    campaign.slice('id', 'name', 'objective', 'daily_budget', 'lifetime_budget').merge(
      'active_adsets_count' => adsets.count { |a| a['effective_status'] == 'ACTIVE' },
      'metrics' => merge_metrics(adsets.map { |a| a['metrics'] }),
      'adsets' => adsets
    )
  end

  def build_adset_node(adset, insights_by_ad_id)
    ads = Array(adset.dig('ads', 'data')).map { |ad| build_ad_node(ad, insights_by_ad_id) }

    adset.slice('id', 'name', 'effective_status', 'daily_budget', 'lifetime_budget').merge(
      'active_ads_count' => ads.count { |ad| ad['effective_status'] == 'ACTIVE' },
      'metrics' => merge_metrics(ads.map { |ad| ad['metrics'] }),
      'ads' => ads
    )
  end

  def build_ad_node(ad, insights_by_ad_id)
    ad.slice('id', 'name', 'effective_status').merge('metrics' => ad_metrics(insights_by_ad_id[ad['id']]))
  end

  def ad_metrics(row)
    return empty_metrics unless row

    actions = Hash.new(0.0)
    Array(row['actions']).each { |a| actions[a['action_type']] += a['value'].to_f }

    {
      'spend' => row['spend'].to_f.round(2),
      'impressions' => row['impressions'].to_i,
      'reach' => row['reach'].to_i,
      'clicks' => row['clicks'].to_i,
      'actions' => actions
    }
  end

  def empty_metrics
    { 'spend' => 0.0, 'impressions' => 0, 'reach' => 0, 'clicks' => 0, 'actions' => {} }
  end

  def merge_metrics(list)
    merged = list.reduce(empty_metrics) do |acc, m|
      {
        'spend' => acc['spend'] + m['spend'],
        'impressions' => acc['impressions'] + m['impressions'],
        'reach' => acc['reach'] + m['reach'],
        'clicks' => acc['clicks'] + m['clicks'],
        'actions' => acc['actions'].merge(m['actions']) { |_type, v1, v2| v1 + v2 }
      }
    end
    merged.merge('spend' => merged['spend'].round(2))
  end

  # Núcleo compartilhado por create_campaign_full (campanha nova) e
  # duplicate_adset_to_campaign (campanha já existente): cria o criativo, o
  # conjunto de anúncios e o anúncio, sempre dentro de um campaign_id que já
  # existe no momento da chamada.
  def create_adset_and_ad(act:, campaign_id:, campanha:, lead_form_id: nil)
    creative = build_creative(act: act, campanha: campanha, lead_form_id: lead_form_id)
    return step_error(creative, 'criativo') unless creative.success

    targeting = resolve_targeting(act: act, targeting: campanha['targeting'] || {})
    return step_error(targeting, 'direcionamento (público/interesses)') unless targeting.success

    promoted_object = promoted_object_for(act: act, campanha: campanha)
    return step_error(promoted_object, 'objeto promovido (pixel/página)') unless promoted_object.success

    adset = post("/#{act}/adsets", {
                    name: campanha['adset_name'],
                    status: campanha['adset_status'].presence || 'PAUSED',
                    campaign_id: campaign_id,
                    daily_budget: campanha['daily_budget'],
                    optimization_goal: campanha['optimization_goal'],
                    bid_strategy: campanha['bid_strategy'],
                    billing_event: 'IMPRESSIONS',
                    destination_type: destination_type_for(campanha),
                    # Exigido pela API pra LEAD_GENERATION ("é necessário um conjunto de
                    # anúncios com objeto promovido") — a Página é o objeto promovido do
                    # próprio formulário de cadastro, não uma URL/evento externo.
                    promoted_object: promoted_object.data&.to_json,
                    targeting: targeting.data.to_json
                  }.compact)
    return step_error(adset, 'conjunto de anúncios') unless adset.success

    ad = create_ad_only(act: act, adset_id: adset.data['id'], creative_id: creative.data['id'], campanha: campanha)
    return ad unless ad.success

    Result.new(success: true, data: [{ 'body' => ad.data.first['body'].merge('adset_id' => adset.data['id']) }])
  end

  # Editar o criativo de um anúncio já publicado: lê o `object_story_spec`
  # atual (preserva page_id/link/call_to_action — não os re-deriva do
  # objetivo como `build_creative`, porque aqui o objetivo já existe e não
  # muda, só o texto/título/imagem que o modal de edição expõe), troca só
  # o que veio preenchido, sobe a imagem nova se houver, cria um AdCreative
  # NOVO com o spec resultante e aponta o anúncio pra ele — nunca dá pra
  # editar um creative_id existente em cima, a Graph API não permite.
  def update_ad_creative(ad_id:, creative_edit:)
    ad = get("/#{ad_id}", fields: 'account_id,creative{object_story_spec}')
    return step_error(ad, 'anúncio (dados do criativo atual)') unless ad.success

    spec = ad.data.dig('creative', 'object_story_spec')
    return Result.new(success: false, error: 'Este anúncio não tem um criativo editável (spec ausente).') if spec.blank?

    spec = spec.deep_dup
    is_video = spec['video_data'].present?
    target = spec['video_data'] || spec['link_data']
    return Result.new(success: false, error: 'Formato de criativo não suportado pra edição.') if target.blank?

    # `link_data` usa a chave `name` pro título (ver `build_creative` acima);
    # só `video_data` usa `title` de verdade. Escrever `title` em `link_data`
    # deixaria o `name` antigo intocado e criaria uma chave nova sem efeito.
    title_key = is_video ? 'title' : 'name'
    target['message'] = creative_edit['body'] if creative_edit['body'].present?
    target[title_key] = creative_edit['title'] if creative_edit['title'].present?

    act = "act_#{ad.data['account_id']}"
    if creative_edit['asset_base64'].present?
      return Result.new(success: false, error: 'Trocar o vídeo de um anúncio existente não é suportado — só imagem.') if is_video

      base64 = creative_edit['asset_base64'].to_s.sub(/\Adata:[^;]+;base64,/, '')
      image = post("/#{act}/adimages", { bytes: base64 })
      return image unless image.success

      image_hash = image.data['images']&.values&.first&.dig('hash')
      return Result.new(success: false, error: 'Upload da nova imagem não retornou hash.') if image_hash.blank?

      target['image_hash'] = image_hash
    end

    creative = post("/#{act}/adcreatives", { object_story_spec: spec.to_json })
    return step_error(creative, 'criativo (novo, com as alterações)') unless creative.success

    updated = post("/#{ad_id}", { creative: { creative_id: creative.data['id'] }.to_json })
    Result.new(success: updated.success, data: [{ 'body' => { 'success' => updated.success } }], error: updated.error)
  end

  def create_ad_only(act:, adset_id:, creative_id:, campanha:)
    ad = post("/#{act}/ads", {
                 name: campanha['ad_name'],
                 status: campanha['ad_status'].presence || 'PAUSED',
                 adset_id: adset_id,
                 creative: { creative_id: creative_id }.to_json
               })
    return step_error(ad, 'anúncio') unless ad.success

    Result.new(success: true, data: [{ 'body' => { 'success' => true, 'ad_id' => ad.data['id'], 'creative_id' => creative_id } }])
  end

  # Extrai a URL pública reaproveitável de um criativo já existente (imagem
  # direta, ou a URL de origem do vídeo) — usado por toda duplicação que lê
  # um anúncio de origem pra recriar o criativo em outro lugar.
  # O criativo tem TRÊS lugares possíveis pra mídia, e nenhum deles serve
  # sozinho — usar só o primeiro era o que fazia toda duplicação de campanha
  # com vídeo falhar com "Não encontrei imagem nem vídeo no anúncio de
  # origem" (confirmado na conta Anuncio Certo Boleto):
  #
  #   1. `image_url`/`thumbnail_url` — só vem em anúncio de imagem.
  #   2. `video_id` (do próprio anúncio) — o `.mp4` (`source`) NÃO vem nesse
  #      caso: vídeo de nível de anúncio/conta não expõe `source` pra este
  #      token, e a Graph devolve o campo simplesmente omitido (sem erro).
  #   3. `object_story_spec.video_data.video_id` — o vídeo que a PÁSTA
  #      realmente é dona; esse sim devolve `source` normalmente.
  #
  # Imagem de anúncio de cadastro/formulário também só existe em
  # `object_story_spec.link_data.picture`, nunca no `image_url` achatado.
  def resolve_creative_source_asset(creative)
    return nil if creative.blank?

    oss = creative['object_story_spec'] || {}
    link_data = oss['link_data'] || {}
    video_data = oss['video_data'] || {}

    image = creative['image_url'].presence ||
            link_data['picture'].presence ||
            video_data['image_url'].presence ||
            creative['thumbnail_url'].presence
    return image if image.present?

    # `video_id` do anúncio primeiro (é o mais comum em campanha criada por
    # este painel) e o do object_story_spec como reserva — os dois podem
    # estar presentes e ser arquivos diferentes, então tenta os dois.
    video_ids = [creative['video_id'], video_data['video_id']].compact.uniq
    video_ids.each do |video_id|
      video = get("/#{video_id}", fields: 'source,picture')
      next unless video.success

      data = video.data || {}
      return data['source'] if data['source'].present?
      return data['picture'] if data['picture'].present?
    end

    nil
  end

  # `asset_base64` continua funcionando (upload direto de bytes, usado pelo
  # modal "Criar Campanha" do painel_trafego.html). `asset_url` é o caminho
  # pra quem só tem um link (ex: Agente de Campanhas por IA, que não tem como
  # gerar bytes de imagem/vídeo direto na conversa) — baixa o arquivo do link
  # informado e converte pra base64 aqui.
  def resolve_asset(campanha)
    if campanha['asset_base64'].present?
      raw = campanha['asset_base64'].to_s.sub(/\Adata:[^;]+;base64,/, '')
      return Result.new(success: true, data: [raw, campanha['asset_mimetype'].to_s])
    end

    url = campanha['asset_url'].to_s
    return Result.new(success: false, error: 'Nenhuma imagem/vídeo informado (asset_base64 ou asset_url).') if url.blank?

    fetch_external_asset(normalize_public_url(url))
  end

  # "Duplicar" no painel abre a tela de criação já preenchida com os dados da
  # campanha de origem. A mídia do anúncio original não volta pro navegador
  # como arquivo (o `adcreative` do painel só traz `image_url`/`video_id`, e
  # vídeo da Meta só tem URL de download via API), então o front manda o
  # `ad_id_origem` e a gente resolve a URL do criativo aqui — tanto imagem
  # quanto vídeo, pelo mesmo caminho da duplicação.
  def resolve_asset_from_source_ad(ad_id_origem)
    criativo = get("/#{ad_id_origem}", fields: 'creative{image_url,thumbnail_url,video_id,object_story_spec}')
    return step_error(criativo, 'anúncio de origem (criativo)') unless criativo.success

    url = resolve_creative_source_asset(criativo.data.to_h['creative'])
    return Result.new(success: false, error: 'Não encontrei imagem nem vídeo no anúncio de origem pra reaproveitar.') if url.blank?

    fetch_external_asset(normalize_public_url(url))
  end

  # Links de compartilhamento do Dropbox (`dl=0`) devolvem uma página HTML de
  # preview, não o arquivo — `dl=1` força o download direto. Outros hosts
  # passam sem alteração.
  def normalize_public_url(url)
    uri = URI.parse(url)
    return url unless uri.host.to_s.include?('dropbox.com')

    query = uri.query.present? ? URI.decode_www_form(uri.query).to_h : {}
    query['dl'] = '1'
    uri.query = URI.encode_www_form(query)
    uri.to_s
  rescue URI::InvalidURIError
    url
  end

  MAX_ASSET_REDIRECTS = 5

  def fetch_external_asset(url, redirects_left: MAX_ASSET_REDIRECTS)
    uri = URI.parse(url)
    return Result.new(success: false, error: "Link inválido: #{url.inspect}") unless uri.is_a?(URI::HTTP)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 20

    response = http.request(Net::HTTP::Get.new(uri.request_uri))

    if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
      return fetch_external_asset(response['location'], redirects_left: redirects_left - 1)
    end

    unless response.is_a?(Net::HTTPSuccess)
      return Result.new(success: false, error: "Não consegui baixar o link informado (HTTP #{response.code}). Verifique se o compartilhamento está público.")
    end

    content_type = response['content-type'].to_s.split(';').first.to_s
    unless content_type.start_with?('image/') || content_type.start_with?('video/')
      return Result.new(
        success: false,
        error: "O link informado não é uma imagem/vídeo direto (recebi \"#{content_type.presence || 'desconhecido'}\"). " \
               'Confirme que o compartilhamento (Dropbox/Drive/etc) está público e aponta pro arquivo, não pra uma página de preview.'
      )
    end

    Result.new(success: true, data: [Base64.strict_encode64(response.body), content_type])
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: fetch_external_asset(#{url}) error: #{e.message}"
    Result.new(success: false, error: "Erro ao baixar o link informado: #{e.message}")
  end

  # O modal "Criar Campanha" monta localização por pin (lat/lng + raio) como
  # `geo_locations.cities[].key = 'custom_location_pin'` — formato que nunca
  # existiu de verdade na Graph API (a chave certa pra pin é
  # `geo_locations.custom_locations[]`, sem key/name). Como esse fluxo nunca
  # tinha sido testado ponta a ponta, normaliza aqui em vez de mexer nos 6
  # formulários do painel_trafego.html.
  # Ponto de entrada: normaliza geo (pin), resolve público salvo/personalizado
  # por nome (campo é um texto livre no modal, não um id) e resolve
  # direcionamento detalhado (nomes de interesse digitados, não ids) — as
  # três coisas que o modal "Criar Campanha" pede mas nunca resolveu de
  # verdade porque `criar_campanha` nunca tinha um backend real por trás.
  def resolve_targeting(act:, targeting:)
    result = normalize_geo(targeting)

    audience_name = targeting['custom_audience_id'].presence || targeting['saved_audience_name'].presence
    if audience_name.present?
      audience = resolve_audience(act: act, name: audience_name)
      return audience unless audience.success

      result = merge_audience(result, audience.data)
    end

    manual = targeting['detailed_targeting_manual']
    if manual.is_a?(Array) && manual.any?
      interests = resolve_interests(terms: manual)
      return interests unless interests.success

      result = result.merge('flexible_spec' => [{ 'interests' => interests.data }]) if interests.data.any?
    end

    # Exigido pela Graph API desde meados de 2024 ("A sinalização de público
    # Advantage é obrigatória") — sem isso a criação do conjunto de anúncios
    # falha com Invalid parameter (subcode 1870227). `0` desliga a expansão
    # automática de público, mantendo exatamente o direcionamento que o
    # modal "Criar Campanha" (ou esta ferramenta) montou.
    result = result.merge('targeting_automation' => { 'advantage_audience' => 0 })

    Result.new(success: true, data: result)
  end

  # O modal "Criar Campanha" monta localização por pin (lat/lng + raio) como
  # `geo_locations.cities[].key = 'custom_location_pin'` — formato que nunca
  # existiu de verdade na Graph API (a chave certa pra pin é
  # `geo_locations.custom_locations[]`, sem key/name).
  # `location_types` virou campo obsoleto na Graph API: a Meta passou a
  # aceitar a cidade/país/raio direto em `geo_locations` e RECUSA o array
  # antigo com o subcode 1870199 — "Agora todo o direcionamento por
  # localização alcançará pessoas que moram ou estiveram recentemente nas
  # localizações selecionadas. Remova todos os valores do campo
  # location_types". Não é opcional: enviar `['cities']` quebra TODA criação
  # de conjunto vinda do painel. A solução é não mandar o campo — a Meta
  # assume o papel de "moram ou estiveram recentemente" por conta própria.
  def normalize_geo(targeting)
    geo = targeting['geo_locations']
    return targeting unless geo.is_a?(Hash)

    geo = geo.reject { |key, _value| key == 'location_types' }

    new_geo = convert_pins_to_custom_locations(geo, 'cities', 'custom_locations')
    # Exclusão de localizações: mesmo pin do mapa, mas no campo de exclusão
    # (`excluded_geo_locations`) — é o que a Meta lê como "não anunciar
    # aqui". Sem converter, o pin com key=custom_location_pin é recusado.
    new_geo = convert_pins_to_custom_locations(new_geo, 'excluded_cities', 'excluded_geo_locations')

    targeting.merge('geo_locations' => new_geo)
  end

  # Move os pins do mapa (`key = 'custom_location_pin'`) do campo de origem
  # para o campo que a Graph API entende (`custom_locations` na inclusão,
  # `excluded_geo_locations` na exclusão), preservando as cidades reais que o
  # modal mandou junto.
  def convert_pins_to_custom_locations(geo, from_key, to_key)
    return geo unless geo[from_key].is_a?(Array)

    pins, real_cities = geo[from_key].partition { |c| c['key'] == 'custom_location_pin' }
    return geo if pins.empty?

    converted = geo.merge(to_key => (geo[to_key] || []) + pins.map do |pin|
      { 'latitude' => pin['latitude'], 'longitude' => pin['longitude'],
        'radius' => pin['radius'], 'distance_unit' => pin['distance_unit'] || 'kilometer' }
    end)
    # `Hash#delete` devolve o valor removido — daí o `dup` + delete separado.
    return converted.except(from_key) if real_cities.empty?

    converted.merge(from_key => real_cities)
  end

  # `custom_audience_id`/`saved_audience_name` no modal são um campo de texto
  # livre (nome digitado), não um id de verdade — procura por nome em
  # públicos salvos (saved_audiences, reaproveita o targeting inteiro salvo)
  # e em públicos personalizados (customaudiences, entra como
  # targeting.custom_audiences).
  def resolve_audience(act:, name:)
    saved = get("/#{act}/saved_audiences", fields: 'id,name,targeting')
    return saved unless saved.success

    match = saved.data.find { |a| a['name'].to_s.casecmp?(name) || a['name'].to_s.include?(name) }
    return Result.new(success: true, data: { type: 'saved', targeting: match['targeting'] }) if match

    custom = get("/#{act}/customaudiences", fields: 'id,name')
    return custom unless custom.success

    match = custom.data.find { |a| a['name'].to_s.casecmp?(name) || a['name'].to_s.include?(name) }
    return Result.new(success: true, data: { type: 'custom', id: match['id'] }) if match

    Result.new(success: false, error: "Nenhum público salvo/personalizado encontrado com o nome \"#{name}\".")
  end

  def merge_audience(targeting, audience)
    if audience[:type] == 'saved'
      # Público salvo é o targeting inteiro reaproveitado — outros campos já
      # escolhidos (idade/geo manual) cedem lugar a ele, é o que "usar esse
      # público salvo" significa na prática.
      targeting.merge(audience[:targeting] || {})
    else
      existing = targeting['custom_audiences'] || []
      targeting.merge('custom_audiences' => existing + [{ 'id' => audience[:id] }])
    end
  end

  # Nomes de interesse digitados à mão (não ids) — resolve cada termo pelo
  # endpoint de busca de interesses da própria Graph API e usa o primeiro
  # resultado (mesma UX do buscador de interesses no Gerenciador de
  # Anúncios: você digita, ele sugere, você aceita a primeira sugestão
  # relevante).
  def resolve_interests(terms:)
    resolved = terms.filter_map do |term|
      result = get('/search', type: 'adinterest', q: term, limit: 1)
      return result unless result.success

      hit = result.data.first
      Rails.logger.warn "Meta::AdsManagerService: nenhum interesse encontrado pra \"#{term}\"" if hit.nil?
      hit && { 'id' => hit['id'], 'name' => hit['name'] }
    end

    Result.new(success: true, data: resolved)
  end

  def step_error(result, step_name)
    Result.new(success: false, data: [{ 'body' => { 'success' => false, 'step' => step_name } }],
               error: "Falha ao criar #{step_name}: #{result.error}")
  end

  # Faz upload da mídia (imagem via bytes base64 direto, vídeo via multipart
  # decodificado do base64) e monta o adcreative (object_story_spec) em
  # cima dela. `link_data`/`video_data` usam a própria página como destino
  # (link: facebook.com/<page_id>) porque o objetivo padrão do modal é
  # "mensagens" (OUTCOME_MESSAGING_CONVERSATIONS) — não há landing page
  # externa nesse fluxo, só o CTA de iniciar conversa.
  def build_creative(act:, campanha:, lead_form_id: nil)
    return build_carousel_creative(act: act, campanha: campanha) if campanha['carousel_items'].is_a?(Array) && campanha['carousel_items'].any?

    if campanha['ad_id_origem'].present?
      asset = resolve_asset_from_source_ad(campanha['ad_id_origem'])
    else
      asset = resolve_asset(campanha)
    end
    return asset unless asset.success
    base64, mimetype = asset.data
    page_id = page_id_for(campanha)
    # Precisa bater com o `destination_type` do adset (ver create_campaign_full)
    # — MESSAGE_PAGE sem isso, ou com um app_destination diferente do adset,
    # é a causa exata do "Incompatibilidade entre criativo e objetivo". O
    # mesmo vale pro CTA de cadastro: SIGN_UP exige o id do formulário já
    # criado (lead_gen_form_id), não dá pra criar o anúncio antes do form.
    cta = if lead_form_id.present?
            { type: 'SIGN_UP', value: { lead_gen_form_id: lead_form_id } }
          elsif messaging_flow?(campanha)
            messaging_cta(campanha)
          else
            { type: 'LEARN_MORE' }
          end

    story_spec = if mimetype.start_with?('video/')
                   # Vídeo não sobe como campo de formulário comum (ao contrário de
                   # imagem via `bytes`) — precisa de multipart de verdade.
                   video = post_multipart_video(act: act, binary: Base64.decode64(base64))
                   return video unless video.success

                   video_id = video.data['id']
                   thumbnail_url = poll_video_thumbnail(video_id: video_id)

                   {
                     page_id: page_id,
                     video_data: {
                       video_id: video_id,
                       image_url: thumbnail_url,
                       message: campanha['body'],
                       title: campanha['title'],
                       call_to_action: cta
                     }
                   }
                 else
                   image = post("/#{act}/adimages", { bytes: base64 })
                   return image unless image.success

                   image_hash = image.data['images']&.values&.first&.dig('hash')
                   return Result.new(success: false, error: 'Upload da imagem não retornou hash.') if image_hash.blank?

                   {
                     page_id: page_id,
                     link_data: {
                       image_hash: image_hash,
                       message: campanha['body'],
                       name: campanha['title'],
                       # A descrição do anúncio só existe em `link_data` (o
                       # `video_data` da Graph API não tem esse campo) e é o
                       # texto de apoio que aparece abaixo do link no feed.
                       description: campanha['description'].presence,
                       # O modal não tem campo de link de destino (foi desenhado só pra
                       # mensagens) — quando vier um `link` de verdade (campanha de
                       # site/tráfego), usa ele; senão cai na própria Página como antes.
                       link: campanha['link'].presence || "https://www.facebook.com/#{page_id}",
                       call_to_action: cta
                     }.compact
                   }
                 end

    post("/#{act}/adcreatives", { object_story_spec: story_spec.to_json })
  end

  # Carrossel — não existe no modal original (só tinha um campo de mídia),
  # mas o formato de `campanha['carousel_items']` segue o mesmo padrão dos
  # outros campos: uma lista de `{asset_base64, title, description, link}`,
  # um por cartão (2 a 10, limite da própria Graph API). Cada cartão sobe
  # como imagem separada (mesmo endpoint `bytes` do criativo de imagem
  # única) antes de montar o `child_attachments`.
  def build_carousel_creative(act:, campanha:)
    page_id = page_id_for(campanha)
    cta = messaging_flow?(campanha) ? messaging_cta(campanha) : { type: 'LEARN_MORE' }
    default_link = campanha['link'].presence || "https://www.facebook.com/#{page_id}"

    child_attachments = campanha['carousel_items'].map do |item|
      base64 = item['asset_base64'].to_s.sub(/\Adata:[^;]+;base64,/, '')
      image = post("/#{act}/adimages", { bytes: base64 })
      return image unless image.success

      image_hash = image.data['images']&.values&.first&.dig('hash')
      return Result.new(success: false, error: "Upload de uma imagem do carrossel (\"#{item['title']}\") não retornou hash.") if image_hash.blank?

      {
        link: item['link'].presence || default_link,
        image_hash: image_hash,
        name: item['title'],
        description: item['description'],
        # "Destino do Messenger ausente em item filho" — quando o CTA do
        # carrossel é MESSAGE_PAGE, a Graph API exige esse MESMO
        # call_to_action em CADA cartão, não só no link_data de fora.
        call_to_action: messaging_flow?(campanha) ? cta : nil
      }.compact
    end

    story_spec = {
      page_id: page_id,
      link_data: {
        message: campanha['body'],
        link: default_link,
        child_attachments: child_attachments,
        call_to_action: cta
      }
    }

    post("/#{act}/adcreatives", { object_story_spec: story_spec.to_json })
  end

  def messaging_flow?(campanha)
    campanha['optimization_goal'].to_s.include?('CONVERSATIONS')
  end

  def lead_flow?(campanha)
    campanha['optimization_goal'].to_s == 'LEAD_GENERATION' || campanha['objective'].to_s == 'OUTCOME_LEADS'
  end

  def instagram_profile_flow?(campanha)
    campanha['optimization_goal'].to_s == 'VISIT_INSTAGRAM_PROFILE'
  end

  def conversion_flow?(campanha)
    campanha['optimization_goal'].to_s == 'OFFSITE_CONVERSIONS'
  end

  def promoted_object_for(act:, campanha:)
    if lead_flow?(campanha)
      Result.new(success: true, data: { page_id: page_id_for(campanha) })
    elsif instagram_profile_flow?(campanha)
      Result.new(success: true, data: { page_id: page_id_for(campanha), instagram_actor_id: instagram_id_for(campanha) })
    elsif messaging_flow?(campanha)
      Result.new(success: true, data: messaging_promoted_object(campanha))
    elsif conversion_flow?(campanha)
      pixel_id = campanha['pixel_id'].presence || resolve_default_pixel_id(act: act)
      return Result.new(success: false, error: 'Nenhum pixel encontrado na conta pra usar como evento de conversão.') if pixel_id.blank?

      Result.new(success: true, data: { pixel_id: pixel_id, custom_event_type: campanha['custom_event_type'].presence || 'PURCHASE' })
    else
      Result.new(success: true, data: nil)
    end
  end

  # Único pixel da conta hoje — evita pedir pra escolher quando só existe um.
  def resolve_default_pixel_id(act:)
    result = get("/#{act}/adspixels", fields: 'id')
    return nil unless result.success

    result.data.first&.dig('id')
  end

  # Normalização exigida pela Graph API pra Custom Audience por lista de
  # clientes antes do hash: sem isso, "João@Email.com " e "joao@email.com"
  # geram hashes diferentes e a Meta não casa o mesmo cliente que já
  # conhece — o valor já deve chegar aqui em minúsculo/trim (email) ou só
  # dígitos (telefone), feito por quem chama.
  def hash_pii(value)
    return nil if value.blank?

    Digest::SHA256.hexdigest(value)
  end

  # `ON_AD`: o formulário abre dentro do próprio anúncio (Instant Form) — é o
  # único destino que a Graph API aceita pra criativo com lead_gen_form_id.
  def destination_type_for(campanha)
    return 'ON_AD' if lead_flow?(campanha)
    return mensagem_destination_type(campanha) if messaging_flow?(campanha)

    nil
  end

  # `ON_AD`: o formulário abre dentro do próprio anúncio (Instant Form) — é o
  # único destino que a Graph API aceita pra criativo com lead_gen_form_id.
  #
  # Mensagens têm VÁRIOS destinos e cada um precisa de um par diferente entre
  # o conjunto (`destination_type`), o `promoted_object` e o CTA do criativo —
  # é a causa exata do "Incompatibilidade entre criativo e objetivo" quando os
  # três não batem. Messenger é o padrão; WhatsApp precisa do número, e
  # Direct/Instagram precisam do perfil da página.
  def mensagem_destination_type(campanha)
    case campanha['mensagem_destino'].presence || 'MESSENGER'
    when 'WHATSAPP' then 'WHATSAPP'
    when 'INSTAGRAM' then 'INSTAGRAM'
    when 'MESSENGER' then 'MESSENGER'
    else 'MESSENGER'
    end
  end

  # `object_story_spec` do conjunto de mensagens. O WhatsApp precisa do
  # `whatsapp_phone_number` (sem ele a Meta recusa o conjunto) e o Direct
  # precisa do `instagram_actor_id` — o mesmo perfil que o CTA do criativo
  # vai usar, senão os dois lados apontam pra destinos diferentes.
  def messaging_promoted_object(campanha)
    case mensagem_destination_type(campanha)
    when 'WHATSAPP'
      phone = campanha['whatsapp_phone_number'].presence
      return { page_id: page_id_for(campanha), smart_pse_enabled: false, whatsapp_phone_number: phone } if phone.present?

      { page_id: page_id_for(campanha) }
    when 'INSTAGRAM'
      { page_id: page_id_for(campanha), instagram_actor_id: instagram_id_for(campanha) }.compact
    else
      { page_id: page_id_for(campanha) }
    end
  end

  # CTA do criativo de mensagens, casando com o `destination_type` do
  # conjunto. Messenger e WhatsApp usam MESSAGE_PAGE; Direct/Instagram usam
  # MESSAGE_PAGE também, mas com o perfil da página no `instagram_actor_id`.
  def messaging_cta(campanha)
    case mensagem_destination_type(campanha)
    when 'WHATSAPP'
      { type: 'WHATSAPP_MESSAGE', value: { app_destination: 'WHATSAPP', link: 'https://api.whatsapp.com/send' } }
    when 'INSTAGRAM'
      actor = instagram_id_for(campanha)
      value = { app_destination: 'MESSENGER', link: "https://m.me/#{page_id_for(campanha)}" }
      value[:instagram_actor_id] = actor if actor.present?
      { type: 'MESSAGE_PAGE', value: value }
    else
      { type: 'MESSAGE_PAGE', value: { app_destination: 'MESSENGER' } }
    end
  end

  # Com CBO a Meta NÃO aceita `LOWEST_COST_WITHOUT_CAP`: ela troca a estratégia
  # para `LOWEST_COST_WITH_BID_CAP` e passa a exigir `bid_amount` (subcode
  # 1815857). Sem teto definido o Gerenciador da Meta pede o valor, então aqui
  # a gente troca a estratégia quando há valor e devolve um erro legível
  # quando não há — melhor que o erro cru da Meta, que só aparece depois de a
  # campanha já ter sido criada.
  def check_bid_amount_for_cbo(adsets_specs)
    sem_teto = adsets_specs.select { |spec| spec['bid_strategy'].to_s.in?(['', 'LOWEST_COST_WITHOUT_CAP']) }
    return nil if sem_teto.empty?

    sem_teto.each do |spec|
      next if bid_amount_cents(spec['bid_amount'])

      return 'Com o orçamento na campanha (CBO) a Meta exige um limite de lance por conjunto. ' \
             "Informe o limite de lance do conjunto \"#{spec['adset_name']}\" (ou volte o orçamento para o conjunto)."
    end

    adsets_specs.map! do |spec|
      if spec['bid_strategy'].to_s.in?(['', 'LOWEST_COST_WITHOUT_CAP'])
        spec.merge('bid_strategy' => 'LOWEST_COST_WITH_BID_CAP')
      else
        spec
      end
    end
    nil
  end

  # Campos do NÍVEL DO CONJUNTO que chegam pelo `overrides` da duplicação.
  # Ficam separados dos de campanha/anúncio de propósito: a página, o destino
  # de conversa e o local de conversão são decididos no conjunto, e mandá-los
  # junto do resto faria o criativo apontar pra um destino e o conjunto pra
  # outro — que é exatamente a "incompatibilidade entre criativo e objetivo"
  # que a Meta reporta. `bid_amount` entra aqui porque o limite de lance só faz
  # sentido junto com `bid_strategy`/`daily_budget`.
  ADSET_LEVEL_OVERRIDE_KEYS = %w[
    page_id
    mensagem_destino
    whatsapp_phone_number
    conversion_location
    conversion_app
    conversion_event
    pixel_id
    daily_budget
    lifetime_budget
    end_time
    description
    bid_strategy
    bid_amount
  ].freeze

  def adset_level_overrides(overrides)
    ADSET_LEVEL_OVERRIDE_KEYS.each_with_object({}) do |key, acc|
      value = overrides[key]
      acc[key] = value if value.present?
    end
  end

  # `bid_amount` (limite de lance / custo-alvo) é o único campo de orçamento da
  # Graph API que vem em CENTAVOS e como inteiro. O front sempre manda no
  # formato de exibição (R$ 15,00); converter aqui evita o "Param bid_amount
  # must be an integer" que a Meta devolve cru.
  def bid_amount_cents(value)
    return nil if value.blank?

    cents = (value.to_s.tr(',', '.').to_f * 100).round
    cents.positive? ? cents : nil
  end

  # Só manda `bid_amount` quando a estratégia de lance aceita um: com
  # LOWEST_COST_WITHOUT_CAP a Meta recusa com 1815858 ("você não pode definir
  # um limite de lance para conjuntos com LOWEST_COST_WITHOUT_CAP"). É
  # exatamente o caso padrão do painel, então enviar o campo sempre quebraria
  # toda criação.
  def bid_amount_for(adset_spec)
    strategy = adset_spec['bid_strategy'].to_s
    return nil unless strategy.in?(%w[LOWEST_COST_WITH_BID_CAP TARGET_COST COST_CAP])

    bid_amount_cents(adset_spec['bid_amount'])
  end

  # `conversion_location` é o "local de conversão" do conjunto: site próprio
  # (URL) ou app. A Meta só aceita o campo em conjunto de objetivo de conversão,
  # então fica fora dos outros (enviar junto é o que faz a API recusar com
  # "Invalid parameter").
  def conversion_location_params(campanha)
    return {} unless conversion_flow?(campanha)

    event = campanha['conversion_event'].presence || 'PURCHASE'
    if campanha['conversion_location'].present?
      { 'conversion_location' => { 'conversion_type' => 'website', 'url' => campanha['conversion_location'],
                                   'event_type' => event }.to_json }
    elsif campanha['conversion_app'].present?
      { 'conversion_location' => { 'conversion_type' => 'app', 'app_id' => campanha['conversion_app'],
                                   'event_type' => event }.to_json }
    else
      {}
    end
  end

  # Formulário de cadastro (Lead Ad / "Instant Form") — precisa existir
  # ANTES do criativo, que só referencia o id dele (call_to_action SIGN_UP).
  # Criado na Página (não na conta de anúncios): é assim que a Graph API
  # espera pra leadgen_forms. Perguntas e política de privacidade vêm do
  # `campanha` se informadas, com um padrão razoável (nome + email,
  # política de privacidade do domínio da página) senão.
  def create_lead_form(campanha:)
    questions = campanha['lead_questions'].presence || [{ type: 'FULL_NAME' }, { type: 'EMAIL' }]
    privacy_url = campanha['privacy_policy_url'].presence || 'https://www.anunciocertobr.com.br/privacidade'

    base_name = campanha['lead_form_name'].presence || "#{campanha['name']} - Formulário"

    # A Meta exige nome ÚNICO de formulário por página e recusa com
    # "O nome do formulário já existe" (subcode 1892019) — duplicar a mesma
    # campanha para Leads duas vezes, ou reexecutar a criação, batia sempre
    # na segunda. Tenta o nome pedido e, se colidir, acresenta um contador.
    result = post(
      "/#{page_id_for(campanha)}/leadgen_forms",
      {
        name: base_name,
        questions: questions.to_json,
        privacy_policy: { url: privacy_url, link_text: 'Política de Privacidade' }.to_json,
        follow_up_action_url: campanha['follow_up_action_url'].presence || "https://www.facebook.com/#{page_id_for(campanha)}"
      },
      page_token_for(campanha)
    )
    return result if result.success

    name_taken = result.error.to_s.include?('1892019') || result.error.to_s.downcase.include?('já existe')
    return result unless name_taken

    2.upto(4) do |n|
      retry_result = post(
        "/#{page_id_for(campanha)}/leadgen_forms",
        {
          name: "#{base_name} (#{n})",
          questions: questions.to_json,
          privacy_policy: { url: privacy_url, link_text: 'Política de Privacidade' }.to_json,
          follow_up_action_url: campanha['follow_up_action_url'].presence || "https://www.facebook.com/#{page_id_for(campanha)}"
        },
        page_token_for(campanha)
      )
      return retry_result if retry_result.success
    end

    result
  end

  # POST multipart de verdade (a Graph API não aceita vídeo como campo de
  # formulário comum em base64, ao contrário de imagem via `bytes`).
  def post_multipart_video(act:, binary:)
    uri = URI("#{BASE_URL}/#{act}/advideos")
    boundary = SecureRandom.hex(16)

    post_body = []
    post_body << "--#{boundary}\r\n"
    post_body << "Content-Disposition: form-data; name=\"access_token\"\r\n\r\n#{@token}\r\n"
    post_body << "--#{boundary}\r\n"
    post_body << "Content-Disposition: form-data; name=\"source\"; filename=\"video.mp4\"\r\n"
    post_body << "Content-Type: video/mp4\r\n\r\n"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri.request_uri)
    request.body = post_body.join + binary.b + "\r\n--#{boundary}--\r\n"
    request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"

    response = http.request(request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::AdsManagerService: POST advideos -> #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao subir o vídeo pra Graph API.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: POST advideos error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao subir o vídeo.')
  end

  # O vídeo recém-enviado ainda está processando quando /advideos retorna —
  # o creative de video_data exige uma thumbnail já pronta, então espera
  # até 20s (Meta costuma gerar a primeira em poucos segundos) antes de
  # desistir e seguir sem thumbnail (a Graph API às vezes aceita mesmo
  # assim e completa depois).
  def poll_video_thumbnail(video_id:)
    8.times do
      result = get("/#{video_id}", fields: 'thumbnails')
      thumb = result.success ? result.data.dig('thumbnails', 'data')&.first&.dig('uri') : nil
      return thumb if thumb.present?

      sleep 2.5
    end
    nil
  end

  # override_token: por padrão nil (usa o user_access_token — o que toda a
  # API de Marketing usa, contas de anúncio, campanhas etc.). Alguns edges de
  # PÁGINA (ex.: /{page_id}/leadgen_forms) exigem especificamente o Page
  # Access Token — a Graph API rejeita com "(#190) This method must be
  # called with a Page Access Token" se receber o token de usuário aqui,
  # mesmo ele tendo a permissão. Nesses casos quem chama passa
  # `@page.page_access_token` como 3º argumento POSICIONAL, não nomeado —
  # um parâmetro nomeado aqui quebraria toda chamada `get(path, campo: val)`
  # já existente no arquivo (Ruby 3 trata `campo: val` como keyword args
  # assim que o método declara QUALQUER parâmetro nomeado, mesmo que a
  # chamada não tivesse nada a ver com ele — já aconteceu, ver commit da
  # correção).
  # A Graph API devolve três coisas e a que ajuda o usuário é a terceira:
  #   message       -> "Invalid parameter" (inglês, genérico, inútil)
  #   error_user_msg-> "Você não pode veicular anúncios de cadastros até sua
  #                    Página aceitar os Termos de Serviço..." (português, diz
  #                    exatamente o que fazer)
  #   error_subcode -> 1815089 (o número que identifica o problema)
  # Antes só a `message` ia pro painel, então toda falha de criação parecia a
  # mesma e o usuário não tinha como descobrir a causa.
  def graph_error_message(parsed, fallback)
    error = parsed.is_a?(Hash) ? parsed['error'] : nil
    return fallback if error.blank?

    parts = []
    parts << error['error_user_msg'].presence || error['message'].presence
    codigo = error['error_subcode'].presence || error['code'].presence
    parts << "(código #{codigo})" if codigo.present?
    parts.compact.join(' ').presence || fallback
  end

  def get(path, params, override_token = nil)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params.merge(access_token: override_token || @token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    response = http.request(Net::HTTP::Get.new(uri.request_uri))
    body = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::AdsManagerService: GET #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: graph_error_message(body, 'Falha ao consultar a Graph API da Meta.'))
    end

    Result.new(success: true, data: body['data'] || body)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: GET #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar a Graph API da Meta.')
  end

  # Ver comentário de `get` acima sobre `override_token` ser posicional.
  def post(path, body, override_token = nil)

    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(body.merge(access_token: override_token || @token))

    response = http.request(request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::AdsManagerService: POST #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: graph_error_message(parsed, 'Falha ao gravar na Graph API da Meta.'))
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: POST #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao gravar na Graph API da Meta.')
  end

  # Só usado por `delete_audience`. Mesmo contrato de `get`/`post`.
  def delete(path, override_token = nil)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(access_token: override_token || @token)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    response = http.request(Net::HTTP::Delete.new(uri.request_uri))
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Meta::AdsManagerService: DELETE #{path} -> #{response.code} #{response.body}"
      return Result.new(success: false, error: graph_error_message(parsed, 'Falha ao excluir na Graph API da Meta.'))
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: DELETE #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao excluir na Graph API da Meta.')
  end
end
