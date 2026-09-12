# == Schema Information
#
# Table name: marketing_alerts
#
#  id         :uuid             not null, primary key
#  body       :text             not null
#  kind       :string           not null
#  read_at    :datetime
#  title      :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_marketing_alerts_on_created_at  (created_at)
#
# Aviso automático de Marketing (relatório semanal ou checagem diária de
# metas) — ver Marketing::AlertDispatcherService, que é quem cria estas
# linhas (só quando o canal "notification" está habilitado em
# MARKETING_ALERTS_CHANNELS).
class MarketingAlert < ApplicationRecord
  KINDS = %w[weekly_report daily_check].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :title, :body, presence: true

  scope :recent_first, -> { order(created_at: :desc) }
  scope :unread, -> { where(read_at: nil) }
end
