require 'securerandom'

# Lista de "clientes/segmentos" acompanhados no Marketing (Meta Ads):
# segmento, canal onde a venda fecha, contas de anúncio, objetivos com
# orçamento/meta de resultado/margem de custo aceita (diário, semanal,
# mensal), e um changelog manual de mudanças na conta/campanha/conjunto/
# anúncio. O acompanhamento automático de "quantos dias fora da meta" roda
# à parte, em Marketing::GoalTrackingJob, e fica salvo em
# MarketingGoalDailyStatus (uma linha por objetivo por dia).
class MarketingClientGoal < ApplicationRecord
  OBJECTIVE_TYPES = %w[mensagens seguidores video alcance vendas_site lead_site outro].freeze
  SALES_CHANNELS = ['Site', 'WhatsApp', 'Loja Física', 'Marketplace', 'Instagram/Direct', 'Telefone', 'Outro'].freeze
  CHANGELOG_LEVELS = %w[conta campanha conjunto anuncio].freeze

  has_many :daily_statuses, class_name: 'MarketingGoalDailyStatus', dependent: :destroy

  validates :name, presence: true
  validate :validate_objectives_structure
  validate :validate_ad_accounts_structure

  before_validation :assign_objective_keys
  before_validation :normalize_blank_jsonb_arrays

  scope :active, -> { where(active: true) }

  def objective(key)
    Array(objectives).find { |o| o['key'] == key }
  end

  private

  def normalize_blank_jsonb_arrays
    self.ad_accounts ||= []
    self.objectives ||= []
    self.changelog ||= []
  end

  def assign_objective_keys
    return unless objectives.is_a?(Array)

    self.objectives = objectives.map do |obj|
      obj = obj.is_a?(Hash) ? obj.stringify_keys : {}
      obj['key'] = obj['key'].presence || SecureRandom.uuid
      obj
    end
  end

  def validate_objectives_structure
    return unless objectives.is_a?(Array)

    objectives.each do |obj|
      type = obj['objective_type']
      unless OBJECTIVE_TYPES.include?(type)
        errors.add(:objectives, "tipo de objetivo inválido: #{type.inspect}")
      end
      if type == 'outro' && obj['custom_label'].blank?
        errors.add(:objectives, "objetivo 'outro' precisa de um rótulo (custom_label)")
      end
    end
  end

  def validate_ad_accounts_structure
    return unless ad_accounts.is_a?(Array)

    ad_accounts.each do |acc|
      errors.add(:ad_accounts, 'cada conta de anúncio precisa de id') if acc['id'].blank?
    end
  end
end
