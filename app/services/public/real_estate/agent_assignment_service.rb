# frozen_string_literal: true

# Public::RealEstate::AgentAssignmentService
#
# Escolhe qual corretor (de REAL_ESTATE_AGENTS, ver RealEstateAgentsDialog.tsx no
# frontend) recebe um lead novo do site de imóveis, segundo as opções
# configuráveis em Organização > Imobiliária:
#   - REAL_ESTATE_LEAD_DISTRIBUTION_MODE: 'queue' (fila/round-robin, padrão),
#     'random' (aleatório) ou 'single' (sempre o mesmo corretor).
#   - REAL_ESTATE_LEAD_DISTRIBUTION_AGENT_SCOPE: 'active' (só corretores ativos,
#     padrão) ou 'all' (ativos e pausados).
#   - REAL_ESTATE_LEAD_DISTRIBUTION_RESPECT_HOURS: "true" para só distribuir pra
#     quem está dentro do próprio horário de atendimento agora.
#   - REAL_ESTATE_LEAD_DISTRIBUTION_SINGLE_AGENT_ID: id do corretor usado quando
#     MODE == 'single'.
#
# Corretores não são User — são registros livres guardados como JSON em
# REAL_ESTATE_AGENTS (sem tabela própria, mesmo padrão de ORG_UNIDADES_JSON) —
# por isso o "próximo da fila" é calculado olhando o último
# custom_fields['assigned_agent_id'] gravado num PipelineItem deste pipeline,
# em vez de um contador à parte (que precisaria de storage próprio e teria
# risco de corrida em GlobalConfig sob concorrência).
class Public::RealEstate::AgentAssignmentService
  TIME_ZONE = 'America/Sao_Paulo'
  # Date#wday: 0 = domingo .. 6 = sábado — mesma convenção de dia usada no
  # formulário de horários do corretor (RealEstateAgentsDialog.tsx) e das
  # unidades da empresa (OrganizationDataPage.tsx).
  WEEKDAY_KEYS = %w[dom seg ter qua qui sex sab].freeze

  def initialize(pipeline:)
    @pipeline = pipeline
  end

  # Retorna o corretor escolhido (Hash, com pelo menos 'id'/'name') ou nil se
  # nenhum corretor está cadastrado/elegível — nesse caso o lead segue sem
  # atribuição, como já acontecia antes deste recurso existir.
  def assign
    eligible = eligible_agents
    return nil if eligible.empty?

    case distribution_mode
    when 'single' then single_agent(eligible)
    when 'random' then eligible.sample
    else next_in_queue(eligible)
    end
  end

  private

  def distribution_mode
    GlobalConfigService.load('REAL_ESTATE_LEAD_DISTRIBUTION_MODE', 'queue').presence || 'queue'
  end

  def agent_scope
    GlobalConfigService.load('REAL_ESTATE_LEAD_DISTRIBUTION_AGENT_SCOPE', 'active').presence || 'active'
  end

  def respect_hours?
    ActiveModel::Type::Boolean.new.cast(GlobalConfigService.load('REAL_ESTATE_LEAD_DISTRIBUTION_RESPECT_HOURS', false))
  end

  def all_agents
    raw = GlobalConfigService.load('REAL_ESTATE_AGENTS', '[]')
    parsed = JSON.parse(raw.presence || '[]')
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end

  def eligible_agents
    agents = all_agents
    agents = agents.select { |a| a['status'] == 'active' } if agent_scope == 'active'
    return agents unless respect_hours?

    # Se ninguém está dentro do horário agora, cai pro conjunto sem essa
    # restrição — melhor atribuir a alguém do que deixar o lead sem corretor.
    agents.select { |a| within_business_hours?(a) }.presence || agents
  end

  def within_business_hours?(agent)
    hours = agent['business_hours']
    return true unless hours.is_a?(Hash) && hours.present? # sem horário cadastrado = sempre disponível

    now = ActiveSupport::TimeZone[TIME_ZONE].now
    day = hours[WEEKDAY_KEYS[now.wday]]
    return false unless day.is_a?(Hash) && !day['closed']

    open_time = parse_time_of_day(day['open'], now)
    close_time = parse_time_of_day(day['close'], now)
    return false unless open_time && close_time

    now.between?(open_time, close_time)
  end

  def parse_time_of_day(str, reference)
    return nil if str.blank?

    hour, minute = str.to_s.split(':').map(&:to_i)
    reference.change(hour: hour, min: minute)
  rescue ArgumentError, TypeError
    nil
  end

  def single_agent(eligible)
    agent_id = GlobalConfigService.load('REAL_ESTATE_LEAD_DISTRIBUTION_SINGLE_AGENT_ID', nil)
    return nil if agent_id.blank?

    eligible.find { |a| a['id'] == agent_id }
  end

  def next_in_queue(eligible)
    last_agent_id = most_recently_assigned_agent_id
    last_index = last_agent_id && eligible.index { |a| a['id'] == last_agent_id }
    return eligible.first if last_index.nil?

    eligible[(last_index + 1) % eligible.size]
  end

  def most_recently_assigned_agent_id
    @pipeline.pipeline_items.order(created_at: :desc).limit(20).each do |item|
      agent_id = item.custom_fields&.dig('assigned_agent_id')
      return agent_id if agent_id.present?
    end
    nil
  end
end
