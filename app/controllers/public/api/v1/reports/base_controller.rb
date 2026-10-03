# frozen_string_literal: true

module Public
  module Api
    module V1
      module Reports
        # Base da API pública que o relatório HTML do link compartilhado usa.
        #
        # A credencial é o token do link, enviado no header `api_access_token`
        # (o IIFE original do HTML anexa esse header em toda chamada /api/; só
        # trocamos o valor da constante).
        #
        # O que este controller GARANTE, e é o ponto todo:
        #
        # * A conta pedida na query é conferida contra `ad_account_ids` do
        #   link. Não é sanitização, é autorização: trocar `ad_account_id` na
        #   URL por outra conta leria a performance de outro cliente. O mesmo
        #   vale para lista de contas e de BMs, que no link só devolvem o que
        #   o dono marcou.
        # * Link revogado ou expirado deixa de responder na hora — não só na
        #   página, mas em cada chamada de dado.
        #
        # Não herda de Api::V1::BaseController de propósito: aquele autentica
        # `api_access_token` contra AccessToken e rejeitaria o token do link.
        class BaseController < ActionController::API
          include ActionController::HttpAuthentication::Token::ControllerMethods

          before_action :authenticate_report_link!

          attr_reader :link

          private

          def authenticate_report_link!
            @link = ReportSnapshot.find_by(token: presented_token)
            return render_link_gone if @link.nil? || !@link.usable?

            @allowed_account_ids = @link.ad_account_ids.map(&:to_s)
          end

          def presented_token
            # Header COM UNDERSCORE não passa pela normalização CGI do Rails.
            # `ActionDispatch::Http::Headers#env_name` só converte para `HTTP_*`
            # o que casa com /\A[a-zA-Z][a-zA-Z0-9-]*\z/ — "api_access_token"
            # tem underscore, então `headers['api_access_token']` procuraria a
            # env key literal e devolveria nil em requisição de verdade (só
            # funciona em teste de integração, que monta a env na mão).
            #
            # Por isso a leitura é da env key crua, que é o que o Puma popula —
            # o mesmo truque que o AccessTokenAuthHelper do app já faz. Sem
            # isso o relatório inteiro volta 410 no navegador e nenhum gráfico
            # renderiza.
            token = request.headers['HTTP_API_ACCESS_TOKEN'].presence ||
                    params[:token].presence ||
                    token_from_authorization_header
            token.to_s
          end

          def token_from_authorization_header
            header = request.headers['Authorization'].to_s
            header.start_with?('Bearer ') ? header.delete_prefix('Bearer ') : nil
          end

          def render_link_gone
            render json: { error: 'Este link expirou ou foi revogado.' }, status: :gone
          end

          # Escopo de contas do link. Chamar em TODO endpoint que fale com a
          # Meta — é o que impede o vazamento entre clientes.
          def allowed_account_ids
            @allowed_account_ids || []
          end

          def account_allowed?(id)
            allowed_account_ids.include?(id.to_s)
          end

          def requested_account_id
            id = params[:ad_account_id].to_s.delete_prefix('act_')
            return id if account_allowed?(id)

            render json: { error: 'Conta de anúncio não autorizada para este link.' }, status: :forbidden
            nil
          end

          # Contas do link, vindas da lista única da integração (uma chamada à Graph).
          #
          # Deliberadamente NÃO aceita business_id: no link público o seletor de
          # BM não pode dirigir a consulta. Versão anterior chamava a Graph uma
          # vez por BM (21 BMs x 2 endpoints = 42 requests sequenciais) e o
          # Rack::Timeout matava a requisição em 15s — a página do cliente
          # abria em branco. A lista de contas do link é fixa por definição, não
          # há o que filtrar por BM.
          def link_scoped_accounts
            accounts = Meta::AdsInsightsService.new.ad_accounts
            return [] unless accounts.success

            Array(accounts.data).filter_map do |a|
              id = (a['account_id'] || a['id'].to_s.delete_prefix('act_')).to_s
              next unless account_allowed?(id)

              { id: id, name: a['name'] }
            end
          end

          def render_meta_error(result)
            render json: { error: result.error }, status: :bad_gateway
          end
        end
      end
    end
  end
end