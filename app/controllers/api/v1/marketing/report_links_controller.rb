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
            :title, :expires_at, :report_type, :include_google_ads, :include_ga4,
            ad_account_ids: [], client_goal_ids: []
          ).tap do |permitted|
            # `delete` (e não só ler) é obrigatório: as listas viram `data` e
            # precisam SAIR dos params, senão ReportSnapshot.new recebe
            # chaves que o model não tem e levanta UnknownAttributeError.
            ad_account_ids = Array(permitted.delete(:ad_account_ids))
            client_goal_ids = Array(permitted.delete(:client_goal_ids))
            google_ads = permitted.delete(:include_google_ads)
            ga4 = permitted.delete(:include_ga4)

            # O front manda "quantos dias vale o link", não a data final —
            # calcular o expires_at aqui evita cliente com fuso/clock errado
            # criar link que já nasce expirado ou que vive além do pedido.
            permitted[:expires_at] = (validity_days.to_i.days.from_now) if validity_days.present?
            permitted[:report_type] ||= ReportSnapshot::MARKETING_CLIENT_GOALS
            permitted[:data] = {
              'ad_account_ids' => ad_account_ids,
              'client_goal_ids' => client_goal_ids,
              'include_google_ads' => truthy?(google_ads),
              'include_ga4' => truthy?(ga4)
            }
          end
        end

        def truthy?(value)
          ActiveModel::Type::Boolean.new.cast(value).present?
        end

        def validity_days
          params.dig(:report_snapshot, :valid_days)
        end

        # Ids enviados que não existem em lugar nenhum.
        #
        # A fonte do "conhecido" depende do tipo do link: no relatório de
        # anúncios as contas vêm da Graph API (é a tela "Relatórios" que lista
        # todas), e uma conta pode perfeitamente não estar em nenhum
        # MarketingClientGoal — validando contra as metas, o dono da conta não
        # conseguiria criar link para conta que ele acabou de cadastrar.
        def unknown_account_ids
          @unknown_account_ids ||= begin
            known = if @link&.ads_report?
                      known_meta_ad_accounts
                    else
                      Array(MarketingClientGoal.all.flat_map { |g| Array(g.ad_accounts).map { |a| a['id'].to_s } })
                    end
            Array(@link&.ad_account_ids).map(&:to_s) - known
          end
        end

        def known_meta_ad_accounts
          result = Meta::AdsInsightsService.new.ad_accounts
          unless result.success
            # Sem lista de contas não dá para validar o que o dono escolheu;
            # melhor gravar o link do que recusar por causa de falha do
            # Instagram — a restrição real (só as contas do link são lidas)
            # é garantida pelo AdsReportsPayload de qualquer forma.
            Rails.logger.warn("[ReportLinksController] ad_accounts indisponível: #{result.error}")
            return Array(@link&.ad_account_ids).map(&:to_s)
          end

          Array(result.data).map { |a| (a['account_id'] || a['id'].to_s.delete_prefix('act_')).to_s }
        rescue StandardError => e
          Rails.logger.warn("[ReportLinksController] ad_accounts exception: #{e.class}: #{e.message}")
          Array(@link&.ad_account_ids).map(&:to_s)
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