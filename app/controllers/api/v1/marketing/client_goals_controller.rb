module Api
  module V1
    module Marketing
      class ClientGoalsController < Api::V1::BaseController
        before_action :fetch_goal, only: %i[show update destroy]

        def index
          scope = params[:include_inactive].present? ? MarketingClientGoal.all : MarketingClientGoal.active
          goals = scope.order(created_at: :desc)
          render json: { success: true, data: goals.map { |g| MarketingClientGoalSerializer.serialize(g) } }
        end

        def show
          render json: { success: true, data: MarketingClientGoalSerializer.serialize(@goal, detailed: true) }
        end

        def create
          @goal = MarketingClientGoal.new(goal_params)
          if @goal.save
            render json: { success: true, data: MarketingClientGoalSerializer.serialize(@goal, detailed: true) }, status: :created
          else
            render json: { success: false, errors: @goal.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @goal.update(goal_params)
            render json: { success: true, data: MarketingClientGoalSerializer.serialize(@goal, detailed: true) }
          else
            render json: { success: false, errors: @goal.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          @goal.destroy
          render json: { success: true, message: 'Removido com sucesso' }
        end

        private

        # Campos de um objective (meta) — os mesmos em qualquer dos 4
        # níveis (conta/campanha/conjunto/anúncio). target_result_{period}
        # é a meta única usada pelo editor em card do nível conta;
        # target_result_{period}_min/max é a faixa usada pelo editor em
        # colunas dos outros 3 níveis — os dois coexistem no mesmo tipo.
        OBJECTIVE_PARAMS = %i[
          key objective_type custom_label budget
          target_result_daily target_result_weekly target_result_monthly
          target_result_daily_min target_result_daily_max
          target_result_weekly_min target_result_weekly_max
          target_result_monthly_min target_result_monthly_max
          cost_margin_daily_min cost_margin_daily_max
          cost_margin_weekly_min cost_margin_weekly_max
          cost_margin_monthly_min cost_margin_monthly_max
        ].freeze

        def fetch_goal
          @goal = MarketingClientGoal.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Não encontrado'] }, status: :not_found
        end

        # ATENÇÃO: `campaigns` (e adsets/ads aninhados) precisa estar aqui
        # explicitamente — strong parameters descarta silenciosamente
        # qualquer chave não permitida antes mesmo de chegar no model, então
        # esquecer um nível aqui parece "não salvou nada" sem erro nenhum
        # (nem chega a rodar a validação do model).
        def goal_params
          params.require(:marketing_client_goal).permit(
            :name, :sales_channel, :meta_budget, :active,
            segments: [],
            ad_accounts: [
              :id, :name, :age_min, :age_max, :gender,
              {
                locations: %i[name radius],
                objectives: OBJECTIVE_PARAMS,
                campaigns: [
                  :id, :name,
                  {
                    objectives: OBJECTIVE_PARAMS,
                    adsets: [
                      :id, :name,
                      {
                        objectives: OBJECTIVE_PARAMS,
                        ads: [
                          :id, :name,
                          { objectives: OBJECTIVE_PARAMS }
                        ]
                      }
                    ]
                  }
                ]
              }
            ],
            changelog: %i[change_date level reference_name description]
          )
        end
      end
    end
  end
end
