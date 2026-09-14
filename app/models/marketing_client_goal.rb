# == Schema Information
#
# Table name: marketing_client_goals
#
#  id            :uuid             not null, primary key
#  active        :boolean          default(TRUE), not null
#  ad_accounts   :jsonb            not null
#  changelog     :jsonb            not null
#  meta_budget   :decimal(10, 2)   default(0.0)
#  name          :string(255)      not null
#  sales_channel :string(100)
#  segments      :jsonb            not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_marketing_client_goals_on_active       (active)
#  index_marketing_client_goals_on_ad_accounts  (ad_accounts) USING gin
#
require 'securerandom'

# Lista de "clientes/segmentos" acompanhados no Marketing (Meta Ads):
# segmento, canal onde a venda fecha, e uma ou mais contas de anúncio — cada
# conta com seus PRÓPRIOS objetivos (orçamento, meta de resultado e margem de
# custo aceita por resultado, diário/semanal/mensal), já que contas
# diferentes do mesmo cliente podem ter metas bem diferentes entre si.
# Objetivos também podem ser definidos mais fundo na hierarquia — campanha,
# conjunto de anúncios, anúncio — dentro de `ad_accounts[].campaigns[]` (e
# aninhados `adsets`/`ads`), pra comparar contra o resultado de uma campanha
# específica em vez de só o agregado da conta; a maioria das contas fica só
# com a meta no nível conta mesmo. Tem também um changelog manual de
# mudanças na conta/campanha/conjunto/anúncio. O acompanhamento automático
# de "quantos dias fora da meta" roda à parte, em Marketing::GoalTrackingJob,
# e fica salvo em MarketingGoalDailyStatus (uma linha por objetivo por dia,
# só no nível conta por enquanto).
class MarketingClientGoal < ApplicationRecord
  OBJECTIVE_TYPES = %w[mensagens seguidores video alcance vendas_site lead_site outro].freeze
  SALES_CHANNELS = ['Site', 'WhatsApp', 'Loja Física', 'Marketplace', 'Instagram/Direct', 'Telefone', 'Outro'].freeze
  CHANGELOG_LEVELS = %w[conta campanha conjunto anuncio].freeze

  has_many :daily_statuses, class_name: 'MarketingGoalDailyStatus', dependent: :destroy

  validates :name, presence: true
  validate :validate_ad_accounts_structure

  before_validation :assign_objective_keys
  before_validation :normalize_blank_jsonb_arrays

  scope :active, -> { where(active: true) }

  private

  def normalize_blank_jsonb_arrays
    self.ad_accounts ||= []
    self.changelog ||= []
    self.segments ||= []
  end

  # Metas (objectives) podem existir em 4 níveis por conta, espelhando a
  # hierarquia real do Meta Ads: conta > campanha > conjunto > anúncio — pra
  # comparar contra o resultado de verdade em qualquer granularidade, não só
  # no agregado da conta inteira. campaigns/adsets/ads só existem quando o
  # usuário decide definir uma meta específica ali (a maioria fica só com a
  # meta da conta mesmo); id/name vêm denormalizados do drill-down ao vivo
  # (Meta::AdsManagerService#account_history_summary) na hora que a meta é
  # criada, pra continuar exibível mesmo se a campanha for arquivada depois.
  def assign_objective_keys
    return unless ad_accounts.is_a?(Array)

    self.ad_accounts = ad_accounts.map { |acc| assign_account_keys(acc) }
  end

  def assign_account_keys(acc)
    acc = acc.is_a?(Hash) ? acc.stringify_keys : {}
    acc.merge(
      'objectives' => assign_keys(acc['objectives']),
      'campaigns' => Array(acc['campaigns']).map { |c| assign_campaign_keys(c) }
    )
  end

  def assign_campaign_keys(camp)
    camp = camp.is_a?(Hash) ? camp.stringify_keys : {}
    camp.merge(
      'objectives' => assign_keys(camp['objectives']),
      'adsets' => Array(camp['adsets']).map { |a| assign_adset_keys(a) }
    )
  end

  def assign_adset_keys(adset)
    adset = adset.is_a?(Hash) ? adset.stringify_keys : {}
    adset.merge(
      'objectives' => assign_keys(adset['objectives']),
      'ads' => Array(adset['ads']).map { |ad| assign_ad_keys(ad) }
    )
  end

  def assign_ad_keys(ad)
    ad = ad.is_a?(Hash) ? ad.stringify_keys : {}
    ad.merge('objectives' => assign_keys(ad['objectives']))
  end

  def assign_keys(objectives)
    Array(objectives).map do |obj|
      obj = obj.is_a?(Hash) ? obj.stringify_keys : {}
      obj.merge('key' => obj['key'].presence || SecureRandom.uuid)
    end
  end

  def validate_ad_accounts_structure
    return unless ad_accounts.is_a?(Array)

    ad_accounts.each do |acc|
      # ID da conta Meta é OPCIONAL: um cliente sem conta de anúncio Meta
      # ligada ainda salva objetivos normalmente, só sem acompanhamento
      # automático (Marketing::GoalTrackingJob pula contas sem id). Exigir id
      # aqui fazia o frontend descartar a conta inteira antes de enviar,
      # silenciosamente, sempre que o cliente não tinha conta Meta cadastrada.
      validate_objectives(acc['objectives'], "conta #{acc['id']}")
      Array(acc['campaigns']).each do |camp|
        validate_objectives(camp['objectives'], "campanha #{camp['name'] || camp['id']}")
        Array(camp['adsets']).each do |adset|
          validate_objectives(adset['objectives'], "conjunto #{adset['name'] || adset['id']}")
          Array(adset['ads']).each do |ad|
            validate_objectives(ad['objectives'], "anúncio #{ad['name'] || ad['id']}")
          end
        end
      end
    end
  end

  def validate_objectives(objectives, label)
    Array(objectives).each do |obj|
      type = obj['objective_type']
      unless OBJECTIVE_TYPES.include?(type)
        errors.add(:ad_accounts, "#{label}: tipo de objetivo inválido: #{type.inspect}")
      end
      if type == 'outro' && obj['custom_label'].blank?
        errors.add(:ad_accounts, "#{label}: objetivo 'outro' precisa de um rótulo (custom_label)")
      end
    end
  end
end
