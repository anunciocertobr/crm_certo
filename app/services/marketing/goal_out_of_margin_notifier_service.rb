# Roda logo depois de Marketing::GoalTrackingService (ver Marketing::GoalTrackingJob)
# — lê o status recém-calculado do dia e cria uma notificação no sino do CRM
# (não confundir com Marketing::DailyAlertService: aquele manda um resumo
# agregado do dia pro canal configurado em MARKETING_ALERTS_CHANNELS
# — notification/whatsapp/email —, esse aqui avisa individualmente, por
# objetivo, só pra quem tem `notify_when_out_of_goal` ligado naquele
# objetivo específico).
module Marketing
  class GoalOutOfMarginNotifierService
    def self.call(date:)
      new(date).call
    end

    def initialize(date)
      @date = date
    end

    def call
      statuses = MarketingGoalDailyStatus.where(date: @date, within_margin: false, marketing_client_goal: MarketingClientGoal.active)
                                          .includes(:marketing_client_goal)
      return if statuses.empty?

      admins = Role.administrator_users
      return if admins.empty?

      statuses.each { |status| notify_for_status(status, admins) }
    end

    private

    def notify_for_status(status, admins)
      goal = status.marketing_client_goal
      account, objective = find_account_and_objective(goal, status.objective_key)
      return if objective.nil?
      # Objetivos criados antes deste campo existir não têm a chave —
      # tratamos como ligado por padrão (preferível a silenciar metas
      # antigas sem o cliente ter desativado o aviso de propósito).
      return unless objective.fetch('notify_when_out_of_goal', true)

      meta = {
        'account_name' => account&.dig('name') || account&.dig('id'),
        'cost_per_result' => status.cost_per_result&.round(2),
        'margin_min' => objective['cost_margin_daily_min'],
        'margin_max' => objective['cost_margin_daily_max'],
        'date' => @date.to_s
      }

      admins.each do |admin|
        Notification.create!(user: admin, notification_type: 'marketing_goal_out_of_margin', primary_actor: goal, meta: meta)
      end
    end

    def find_account_and_objective(goal, objective_key)
      Array(goal.ad_accounts).each do |acc|
        obj = Array(acc['objectives']).find { |o| o['key'] == objective_key }
        return [acc, obj] if obj
      end
      [nil, nil]
    end
  end
end
