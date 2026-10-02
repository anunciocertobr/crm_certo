# frozen_string_literal: true

module Api
  module V1
    module Marketing
      # CRUD dos links públicos de relatório (rotas autenticadas — só quem
      # está logado no CRM cria/lista/revoga). A leitura pelo link em si é
      # pública e fica em Api::V1::Public::ReportLinksController.
      class ReportLinksController < Api::V1::BaseController
        before_action :fetch_link, only: %i[revoke]

        def index
          links = ReportSnapshot.order(created_at: :desc)
          render json: { success: true, data: links.map { |link| serialize_link(link) } }
        end

        def create
          @link = ReportSnapshot.new(link_params)

          # Conta que não existe em nenhuma meta é quase sempre digitação errada
          # na tela. Validado ANTES do save de propósito: link com conta
          # inválida é um link que não mostra nada (ruim), e se fosse salvo
          # antes da checagem ficaria persistido mesmo com a resposta 422.
          if unknown_account_ids.any?
            @link.errors.add(:ad_account_ids, "conta(s) não encontrada(s): #{unknown_account_ids.join(', ')}")
            return render json: { success: false, errors: @link.errors.full_messages }, status: :unprocessable_entity
          end

          if @link.save
            render json: { success: true, data: serialize_link(@link) }, status: :created
          else
            render json: { success: false, errors: @link.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def revoke
          @link.revoke!
          render json: { success: true, data: serialize_link(@link) }
        end

        private

        def fetch_link
          @link = ReportSnapshot.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Link não encontrado'] }, status: :not_found
        end

        def link_params
          params.require(:report_snapshot).permit(
            :title, :expires_at, :report_type, ad_account_ids: [], client_goal_ids: []
          ).tap do |permitted|
            # O front manda "quantos dias vale o link", não a data final —
            # calcular o expires_at aqui evita cliente com fuso/clock errado
            # criar link que já nasce expirado ou que vive além do pedido.
            permitted[:expires_at] = (validity_days.to_i.days.from_now) if validity_days.present?
            permitted[:report_type] ||= ReportSnapshot::MARKETING_CLIENT_GOALS
            permitted[:data] = {
              'ad_account_ids' => Array(permitted[:ad_account_ids]),
              'client_goal_ids' => Array(permitted[:client_goal_ids])
            }
          end
        end

        def validity_days
          params.dig(:report_snapshot, :valid_days)
        end

        # Ids enviados que não existem em nenhum MarketingClientGoal.
        def unknown_account_ids
          @unknown_account_ids ||= begin
            known = MarketingClientGoal.all.flat_map do |goal|
              Array(goal.ad_accounts).map { |acc| acc['id'].to_s }
            end
            Array(@link&.ad_account_ids).map(&:to_s) - known
          end
        end

        def serialize_link(link)
          {
            id: link.id,
            title: link.title,
            report_type: link.report_type,
            token: link.token,
            url: public_url(link.token),
            ad_account_ids: link.ad_account_ids,
            expires_at: link.expires_at&.iso8601,
            days_left: link.days_left,
            revoked_at: link.revoked_at&.iso8601,
            usable: link.usable?,
            created_at: link.created_at&.iso8601
          }
        end

        # Mesmo esquema do Meta::ClientAccessService. Se FRONTEND_URL não
        # estiver no ambiente, devolve o caminho em vez de falhar: o front
        # completa com a própria origem, e o link segue utilizável.
        def public_url(token)
          base = ENV['FRONTEND_URL'].to_s.strip.gsub(%r{/+\z}, '')
          path = "/r/#{CGI.escape(token)}"
          base.presence ? "#{base}#{path}" : path
        end
      end
    end
  end
end