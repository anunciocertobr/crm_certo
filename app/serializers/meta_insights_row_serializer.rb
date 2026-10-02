# frozen_string_literal: true

# Transformação de uma linha de insights da Meta no formato do relatório
# (português, com vírgula decimal e custo por resultado já calculado).
#
# Vive fora do controller porque DOIS lugares precisam exatamente da mesma
# transformação: a rota autenticada de /reports/meta_ads/insights (o relatório
# interno do CRM) e a rota pública do link compartilhado. Se cada um tivesse a
# sua versão, o cliente abriria o link e veria números com cara diferente dos
# que o dono da conta vê na tela interna — e qualquer correção em um dos dois
# passaria despercebida no outro.
module MetaInsightsRowSerializer
  ACTION_TYPES = {
    'onsite_conversion.messaging_conversation_started_7d' => :mensagens,
    'link_click' => :link_click,
    'offsite_conversion.fb_pixel_lead' => :leads_pixel,
    'lead' => :leads_ads
  }.freeze

  module_function

  def serialize(row, conteudo)
    actions = tally_actions(row['actions'])
    spend = row['spend'].to_f
    impressions = row['impressions'].to_i
    reach = row['reach'].to_i

    custo = ->(valor) { valor.positive? ? format('%.2f', spend / valor).tr('.', ',') : '0,00' }

    base = {
      'Data' => row['date_start'],
      'Campanha' => row['campaign_name'],
      'Conjunto de Anúncios' => row['adset_name'],
      'Anúncio' => row['ad_name'],
      'Gasto' => format('%.2f', spend).tr('.', ','),
      'Mensagens' => actions[:mensagens],
      'Custo por Mensagens' => custo.call(actions[:mensagens]),
      'Cliques' => actions[:link_click],
      'CPC' => custo.call(actions[:link_click]),
      'Impressões' => impressions,
      'CPM' => impressions.positive? ? custo.call(impressions / 1000.0) : '0,00',
      'Alcance' => reach,
      'Frequência' => reach.positive? ? format('%.2f', impressions.to_f / reach).tr('.', ',') : '0,00',
      'Objetivo' => row['objective'],
      'Leads do Pixel' => actions[:leads_pixel],
      'Custo por Leads Pixel' => custo.call(actions[:leads_pixel]),
      'Leads do Meta Ads' => actions[:leads_ads],
      'Custo por Leads Ads' => custo.call(actions[:leads_ads])
    }

    base.merge(breakdown_fields(conteudo, row))
  end

  def breakdown_fields(conteudo, row)
    case conteudo
    when 'hora'
      { 'Hora (Audience TZ)' => row['hourly_stats_aggregated_by_audience_time_zone'] || 'N/A' }
    when 'idade_genero'
      { 'Idade' => row['age'] || 'N/A', 'Gênero' => row['gender'] || 'N/A' }
    when 'regiao'
      { 'Região' => row['region'] || 'N/A' }
    when 'posicionamento'
      {
        'Impression Device' => row['impression_device'] || 'N/A',
        'Device Platform' => row['device_platform'] || 'N/A',
        'Platform Position' => row['platform_position'] || 'N/A',
        'Publisher Platform' => row['publisher_platform'] || 'N/A'
      }
    else
      {}
    end
  end

  def tally_actions(actions)
    totals = { mensagens: 0, link_click: 0, leads_pixel: 0, leads_ads: 0 }
    Array(actions).each do |action|
      key = ACTION_TYPES[action['action_type']]
      totals[key] += action['value'].to_i if key
    end
    totals
  end
end