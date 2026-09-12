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
# diferentes do mesmo cliente podem ter metas bem diferentes entre si. Tem
# também um changelog manual de mudanças na conta/campanha/conjunto/anúncio.
# O acompanhamento automático de "quantos dias fora da meta" roda à parte,
# em Marketing::GoalTrackingJob, e fica salvo em MarketingGoalDailyStatus
# (uma linha por objetivo por dia).
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

  def assign_objective_keys
    return unless ad_accounts.is_a?(Array)

    self.ad_accounts = ad_accounts.map do |acc|
      acc = acc.is_a?(Hash) ? acc.stringify_keys : {}
      objectives = Array(acc['objectives']).map do |obj|
        obj = obj.is_a?(Hash) ? obj.stringify_keys : {}
        obj['key'] = obj['key'].presence || SecureRandom.uuid
        obj
      end
      acc.merge('objectives' => objectives)
    end
  end

  def validate_ad_accounts_structure
    return unless ad_accounts.is_a?(Array)

    ad_accounts.each do |acc|
      if acc['id'].blank?
        errors.add(:ad_accounts, 'cada conta de anúncio precisa de id')
        next
      end

      Array(acc['objectives']).each do |obj|
        type = obj['objective_type']
        unless OBJECTIVE_TYPES.include?(type)
          errors.add(:ad_accounts, "conta #{acc['id']}: tipo de objetivo inválido: #{type.inspect}")
        end
        if type == 'outro' && obj['custom_label'].blank?
          errors.add(:ad_accounts, "conta #{acc['id']}: objetivo 'outro' precisa de um rótulo (custom_label)")
        end
      end
    end
  end
end
