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

  def initialize
    @page = Channel::FacebookPage.first
    @token = @page&.user_access_token
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

  def campaigns_tree(ad_account_id:, date_start:, date_stop:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    structural = get(
      "/act_#{ad_account_id}/campaigns",
      fields: 'id,name,status,objective,' \
              'adsets{name,status,daily_budget,targeting,promoted_object,start_time,end_time,' \
              'optimization_goal,bid_strategy,ads{name,status,adcreative{name,body,image_url,video_id}}}',
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

  def creative_details(ad_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    ad = get("/#{ad_id}", fields: 'name,creative{name,body,title,image_url,thumbnail_url,video_id}')
    return ad unless ad.success

    creative = ad.data['creative'] || {}
    video = {}
    if creative['video_id'].present?
      video_result = get("/#{creative['video_id']}", fields: 'permalink_url,source')
      video = video_result.success ? video_result.data : {}
    end

    Result.new(success: true, data: [{
      'imagem' => creative['image_url'],
      'video' => video['source'],
      'thumbnail_url' => creative['thumbnail_url'] || video['permalink_url']
    }])
  end

  # nivel: 'campaign' | 'adset' | 'ad'. edicao: hash já filtrado por
  # EDITABLE_FIELDS pelo controller antes de chegar aqui.
  def update(id:, edicao:)
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
      fields: 'name,adsets.limit(1){name,daily_budget,targeting,ads.limit(1){name,creative{body,title,image_url,video_id}}}'
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
      'targeting' => adset['targeting'] || {}
    }.compact

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
    return Result.new(success: false, error: 'Página do Facebook sem page_id configurado (necessário pro criativo).') if @page&.page_id.blank?

    act = "act_#{ad_account_id}"

    lead_form_id = nil
    if lead_flow?(campanha)
      lead_form = create_lead_form(campanha: campanha)
      return step_error(lead_form, 'formulário de cadastro') unless lead_form.success

      lead_form_id = lead_form.data['id']
    end

    campaign = post("/#{act}/campaigns", {
                       name: campanha['name'],
                       status: campanha['status'].presence || 'PAUSED',
                       objective: campanha['objective'],
                       special_ad_categories: [].to_json,
                       # Exigido pela API quando o orçamento é definido no conjunto de
                       # anúncios (como aqui), não na campanha (CBO) — sem isso a Graph
                       # API recusa a criação com "Invalid parameter" (subcode 4834011).
                       is_adset_budget_sharing_enabled: false
                     })
    return step_error(campaign, 'campanha') unless campaign.success

    # `adsets` (novo): array de conjuntos, cada um com seu próprio `ads` —
    # suporta criar uma campanha com vários conjuntos/anúncios de uma vez
    # (pedido do usuário: duplicar Conjunto/Anúncio ao montar a campanha,
    # cada conjunto com seu próprio mapa/localização/público no front).
    # Sem essa chave, cai no formato antigo achatado (um conjunto + um
    # anúncio só, campos direto em `campanha`) — mantém compatibilidade
    # total com duplicate_adset_to_campaign, que só sabe montar esse formato.
    adsets_specs = campanha['adsets'].presence || [campanha]

    created_adsets = []
    adsets_specs.each do |adset_spec|
      result = create_adset_with_ads(act: act, campaign_id: campaign.data['id'], adset_spec: adset_spec, lead_form_id: lead_form_id)
      return result unless result.success

      created_adsets << result.data
    end

    Result.new(success: true, data: [{ 'body' => { 'success' => true, 'campaign_id' => campaign.data['id'], 'adsets' => created_adsets } }])
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
                    daily_budget: adset_spec['daily_budget'],
                    optimization_goal: adset_spec['optimization_goal'],
                    bid_strategy: adset_spec['bid_strategy'],
                    billing_event: 'IMPRESSIONS',
                    destination_type: destination_type_for(adset_spec),
                    promoted_object: promoted_object.data&.to_json,
                    targeting: targeting.data.to_json
                  }.compact)
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
      fields: 'name,daily_budget,targeting,ads.limit(1){name,creative{body,title,image_url,video_id}}'
    )
    return step_error(source, 'conjunto de origem') unless source.success

    ad = source.data.dig('ads', 'data', 0)
    return Result.new(success: false, error: 'O conjunto de origem não tem anúncio pra copiar.') if ad.blank?

    creative = ad['creative'] || {}
    asset_url = resolve_creative_source_asset(creative)
    return Result.new(success: false, error: 'Não encontrei imagem nem vídeo no anúncio de origem pra reaproveitar.') if asset_url.blank?

    target_objective = target_campaign.data['objective']
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
      'targeting' => source.data['targeting'] || {}
    }.compact

    lead_form_id = nil
    if lead_flow?(campanha)
      lead_form = create_lead_form(campanha: campanha)
      return step_error(lead_form, 'formulário de cadastro') unless lead_form.success

      lead_form_id = lead_form.data['id']
    end

    create_adset_and_ad(act: act, campaign_id: target_campaign_id, campanha: campanha, lead_form_id: lead_form_id)
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

    source_ad = get("/#{source_ad_id}", fields: 'name,creative{body,title,image_url,video_id}')
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
      'asset_url' => asset_url
    }.compact

    lead_form_id = nil
    if lead_flow?(campanha)
      lead_form = create_lead_form(campanha: campanha)
      return step_error(lead_form, 'formulário de cadastro') unless lead_form.success

      lead_form_id = lead_form.data['id']
    end

    creative = build_creative(act: act, campanha: campanha, lead_form_id: lead_form_id)
    return step_error(creative, 'criativo') unless creative.success

    create_ad_only(act: act, adset_id: target_adset_id, creative_id: creative.data['id'], campanha: campanha)
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
  def pages_for_business(business_id:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    fields = 'id,name'
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

  # retention_days: janela de quem entra no público (1-180, limite da própria
  # Graph API). Sem url_contains, usa todo mundo que visitou o site
  # (PageView) em vez de uma página específica.
  def create_website_audience(ad_account_id:, name:, pixel_id:, retention_days:, url_contains: nil, description: nil)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    filter = if url_contains.present?
               { field: 'url', operator: 'i_contains', value: url_contains }
             else
               { field: 'event', operator: 'eq', value: 'PageView' }
             end
    rule = {
      inclusions: {
        operator: 'or',
        rules: [
          {
            event_sources: [{ type: 'pixel', id: pixel_id }],
            retention_seconds: retention_days.to_i.clamp(1, 180) * 86_400,
            filter: { operator: 'and', filters: [filter] }
          }
        ]
      }
    }

    post("/act_#{id}/customaudiences", {
      name: name,
      subtype: 'WEBSITE',
      description: description,
      rule: rule.to_json
    }.compact)
  end

  # ratio: 0.01 a 0.20 (1% a 20% do país, granularidade mínima da própria
  # Graph API pra Lookalike).
  def create_lookalike_audience(ad_account_id:, name:, origin_audience_id:, country:, ratio:)
    return Result.new(success: false, error: 'Página do Facebook não conectada.') unless connected?

    id = ad_account_id.to_s.delete_prefix('act_')
    post("/act_#{id}/customaudiences", {
      name: name,
      subtype: 'LOOKALIKE',
      origin_audience_id: origin_audience_id,
      lookalike_spec: { type: 'similarity', country: country, ratio: ratio.to_f.clamp(0.01, 0.20) }.to_json
    })
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

  private

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
  def resolve_creative_source_asset(creative)
    return creative['image_url'] if creative['image_url'].present?
    return nil if creative['video_id'].blank?

    video = get("/#{creative['video_id']}", fields: 'source')
    video.success ? video.data['source'] : nil
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
  def normalize_geo(targeting)
    geo = targeting['geo_locations']
    return targeting unless geo.is_a?(Hash) && geo['cities'].is_a?(Array)

    pins, real_cities = geo['cities'].partition { |c| c['key'] == 'custom_location_pin' }
    return targeting if pins.empty?

    custom_locations = pins.map do |pin|
      { 'latitude' => pin['latitude'], 'longitude' => pin['longitude'],
        'radius' => pin['radius'], 'distance_unit' => pin['distance_unit'] || 'kilometer' }
    end

    new_geo = geo.merge('custom_locations' => (geo['custom_locations'] || []) + custom_locations)
    if real_cities.empty?
      new_geo.delete('cities')
    else
      new_geo['cities'] = real_cities
    end

    targeting.merge('geo_locations' => new_geo)
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

    asset = resolve_asset(campanha)
    return asset unless asset.success

    base64, mimetype = asset.data
    page_id = @page.page_id
    # Precisa bater com o `destination_type` do adset (ver create_campaign_full)
    # — MESSAGE_PAGE sem isso, ou com um app_destination diferente do adset,
    # é a causa exata do "Incompatibilidade entre criativo e objetivo". O
    # mesmo vale pro CTA de cadastro: SIGN_UP exige o id do formulário já
    # criado (lead_gen_form_id), não dá pra criar o anúncio antes do form.
    cta = if lead_form_id.present?
            { type: 'SIGN_UP', value: { lead_gen_form_id: lead_form_id } }
          elsif messaging_flow?(campanha)
            { type: 'MESSAGE_PAGE', value: { app_destination: 'MESSENGER' } }
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
                       # O modal não tem campo de link de destino (foi desenhado só pra
                       # mensagens) — quando vier um `link` de verdade (campanha de
                       # site/tráfego), usa ele; senão cai na própria Página como antes.
                       link: campanha['link'].presence || "https://www.facebook.com/#{page_id}",
                       call_to_action: cta
                     }
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
    page_id = @page.page_id
    cta = messaging_flow?(campanha) ? { type: 'MESSAGE_PAGE', value: { app_destination: 'MESSENGER' } } : { type: 'LEARN_MORE' }
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
      Result.new(success: true, data: { page_id: @page.page_id })
    elsif instagram_profile_flow?(campanha)
      Result.new(success: true, data: { page_id: @page.page_id, instagram_actor_id: @page.instagram_id })
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

  # ON_AD: o formulário abre dentro do próprio anúncio (Instant Form) — é o
  # único destino que a Graph API aceita pra criativo com lead_gen_form_id.
  def destination_type_for(campanha)
    return 'ON_AD' if lead_flow?(campanha)
    return 'MESSENGER' if messaging_flow?(campanha)

    nil
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

    post(
      "/#{@page.page_id}/leadgen_forms",
      {
        name: campanha['lead_form_name'].presence || "#{campanha['name']} - Formulário",
        questions: questions.to_json,
        privacy_policy: { url: privacy_url, link_text: 'Política de Privacidade' }.to_json,
        follow_up_action_url: campanha['follow_up_action_url'].presence || "https://www.facebook.com/#{@page.page_id}"
      },
      @page.page_access_token
    )
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
      return Result.new(success: false, error: body.dig('error', 'message') || 'Falha ao consultar a Graph API da Meta.')
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
      return Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao gravar na Graph API da Meta.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Meta::AdsManagerService: POST #{path} error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao gravar na Graph API da Meta.')
  end
end
