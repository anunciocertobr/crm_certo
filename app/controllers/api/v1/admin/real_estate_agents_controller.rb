# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Dados do Kanban "Imobiliária" agregados por corretor — usado na tabela de
      # corretores (RealEstateAgentsDialog.tsx) pra mostrar quantos leads cada um
      # tem e em que etapa estão, sem expor o pipeline_items API genérico (que
      # exige pipeline_id e a policy de pipelines) pra essa tela.
      class RealEstateAgentsController < Api::V1::Admin::BaseController
        PIPELINE_NAME = 'Imobiliária'

        def kanban_stats
          pipeline = Pipeline.find_by(name: PIPELINE_NAME)
          return success_response(data: { agents: {} }) unless pipeline

          items_by_agent = pipeline.pipeline_items.includes(:pipeline_stage).group_by do |item|
            item.custom_fields&.dig('assigned_agent_id')
          end
          items_by_agent.delete(nil)

          agents = items_by_agent.transform_values do |items|
            stage_counts = items.group_by { |item| item.pipeline_stage.name }
                                 .transform_values(&:count)
                                 .map { |name, count| { name: name, count: count } }
            { total: items.size, stages: stage_counts }
          end

          success_response(data: { agents: agents })
        end

        # Leads (PipelineItem) atribuídos a um corretor específico — usado no
        # drill-down "clicar no total de leads" da tabela de corretores, pra
        # montar o cartão de lead (data, imóvel, contato) e os botões de
        # reenvio por email/WhatsApp (RealEstateAgentLeadsDialog.tsx).
        def leads
          pipeline = Pipeline.find_by(name: PIPELINE_NAME)
          return success_response(data: { leads: [] }) unless pipeline

          items = pipeline.pipeline_items
                          .includes(:contact, :pipeline_stage)
                          .where("custom_fields ->> 'assigned_agent_id' = ?", params[:agent_id])
                          .order(created_at: :desc)

          leads = items.map do |item|
            {
              id: item.id,
              created_at: item.created_at,
              stage_name: item.pipeline_stage.name,
              product_name: item.custom_fields['product_name'],
              message: item.custom_fields['message'],
              contact: {
                name: item.contact&.name,
                phone: item.contact&.phone_number,
                email: item.contact&.email
              }
            }
          end

          success_response(data: { leads: leads })
        end
      end
    end
  end
end
