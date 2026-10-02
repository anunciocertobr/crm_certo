# == Schema Information
#
# Table name: report_snapshots
#
#  id            :uuid             not null, primary key
#  created_at    :datetime         not null
#  data          :jsonb            default({}), not null
#  expires_at    :datetime         not null
#  report_type   :string           not null
#  revoked_at    :datetime
#  title         :string
#  token         :string           not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_report_snapshots_on_expires_at  (expires_at)
#  index_report_snapshots_on_token       (token) UNIQUE
#
# Link público de relatório. Despite o nome "snapshot", NÃO guarda uma cópia
# congelada dos dados: `data` guarda só a CONFIGURAÇÃO do link (hoje só a
# lista `ad_account_ids` de contas de anúncio que quem abre pode ver), e os
# números são lidos ao vivo a cada requisição. Isso porque quem recebe o link é
# o cliente final, que abre ao longo de dias e precisa ver o resultado de
# hoje — um snapshot congelado na criação ficaria velho no dia seguinte.
#
# O escopo por conta é aplicado NO SERVIDOR (PublicReportSerializer), nunca só
# no front: se a filtragem ficasse no cliente, qualquer pessoa com o link
# trocaria a chamada e leria as metas de outras contas.
class ReportSnapshot < ApplicationRecord
  MARKETING_CLIENT_GOALS = 'marketing_client_goals'.freeze
  REPORT_TYPES = [MARKETING_CLIENT_GOALS].freeze

  # Prazo máximo: um link de relatório com validade de anos na prática é um
  # link sem prazo, e o risco de vazar dado de cliente cresce com o tempo.
  MAX_VALIDITY_DAYS = 365

  validates :report_type, inclusion: { in: REPORT_TYPES }
  validates :token, presence: true, uniqueness: true
  validates :title, presence: true
  validates :expires_at, presence: true
  validate :validate_ad_account_ids
  validate :validate_expires_at

  before_validation :assign_token, on: :create

  scope :usable, -> { where(revoked_at: nil).where(arel_table[:expires_at].gt(Time.current)) }

  # Ids das contas de anúncio que quem abre o link pode ver. Ficam em `data`
  # (jsonb) porque `data` é a configuração do link; `data` também guarda
  # `client_goal_ids` quando o link não deve incluir todas as metas.
  def ad_account_ids
    Array(data&.dig('ad_account_ids')).map(&:to_s).reject(&:blank?)
  end

  # Metas de cliente que o link inclui. Vazio = todas (ainda filtradas por
  # ad_account_ids, que é a restrição que importa).
  def client_goal_ids
    Array(data&.dig('client_goal_ids')).map(&:to_s).reject(&:blank?)
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.blank? || expires_at <= Time.current
  end

  def usable?
    !revoked? && !expired?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def days_left
    return 0 if expired?

    ((expires_at - Time.current) / 1.day).ceil
  end

  private

  # SecureRandom e não contador/sequência: o token é a única credencial do
  # link, então precisa ser imprevisível — adivinhar o próximo link daria
  # acesso aos relatórios de qualquer cliente.
  def assign_token
    self.token ||= loop do
      candidate = SecureRandom.urlsafe_base64(24)
      break candidate unless self.class.exists?(token: candidate)
    end
  end

  def validate_ad_account_ids
    if ad_account_ids.empty?
      errors.add(:ad_account_ids, 'selecione ao menos uma conta de anúncio')
    end
  end

  def validate_expires_at
    return if expires_at.blank?

    if expires_at <= Time.current
      errors.add(:expires_at, 'a validade precisa estar no futuro')
    elsif expires_at > Time.current + MAX_VALIDITY_DAYS.days
      errors.add(:expires_at, "a validade não pode passar de #{MAX_VALIDITY_DAYS} dias")
    end
  end
end