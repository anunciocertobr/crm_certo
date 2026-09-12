# == Schema Information
#
# Table name: marketing_goal_daily_statuses
#
#  id                       :uuid             not null, primary key
#  cost_per_result          :decimal(12, 4)
#  date                     :date             not null
#  objective_key            :string(100)      not null
#  results                  :decimal(14, 4)   default(0.0)
#  spend                    :decimal(12, 2)   default(0.0)
#  within_margin            :boolean
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  marketing_client_goal_id :uuid             not null
#
# Indexes
#
#  index_goal_daily_statuses_on_goal_objective_date  (marketing_client_goal_id,objective_key,date) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (marketing_client_goal_id => marketing_client_goals.id)
#
# Uma linha por objetivo (dentro de um MarketingClientGoal) por dia,
# gravada automaticamente por Marketing::GoalTrackingJob comparando o gasto
# e resultado real da(s) conta(s) de anúncio do cliente (Meta Graph API)
# contra a margem de custo por resultado definida em cada objetivo.
class MarketingGoalDailyStatus < ApplicationRecord
  belongs_to :marketing_client_goal

  scope :for_objective, ->(key) { where(objective_key: key) }
  scope :recent_first, -> { order(date: :desc) }

  # Quantos dias seguidos (terminando no dia mais recente já calculado)
  # este objetivo ficou fora da margem — usado pra montar a observação tipo
  # "3 dias fora da meta". within_margin=nil (objetivo sem forma de medir
  # automaticamente) nunca conta como streak.
  def self.consecutive_out_of_margin_streak(marketing_client_goal_id:, objective_key:)
    rows = where(marketing_client_goal_id: marketing_client_goal_id, objective_key: objective_key)
           .order(date: :desc).limit(90).pluck(:date, :within_margin)
    streak = 0
    rows.each do |(_date, within_margin)|
      break if within_margin.nil? || within_margin == true

      streak += 1
    end
    streak
  end
end
