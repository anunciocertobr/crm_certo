# frozen_string_literal: true

module Public
  module Api
    module V1
      module Reports
        # Meta Ads do link público. Espelha Api::V1::Reports::MetaAdsController,
        # com duas diferenças que importam:
        #
        # * `insights` só roda para contas marcadas no link (BaseController);
        # * contas e BMs devolvem só o que o link permite — a tela original lista
        #   todas as contas da integração, o que num link vazaria o nome de
        #   contas de outros clientes.
        #
        # A linha das campanhas sai pelo MESMO MetaInsightsRowSerializer da rota
        # interna, então o cliente não vê números diferentes dos do dono.
        class MetaAdsController < BaseController
          def insights
            account_id = requested_account_id
            return if account_id.nil?

            conteudo = params[:conteudo].presence || 'geral'
            result = Meta::AdsInsightsService.new.campaign_insights(
              ad_account_id: account_id,
              conteudo: conteudo,
              date_start: params.require(:date_start),
              date_stop: params.require(:date_stop)
            )
            return render_meta_error(result) unless result.success

            render json: Array(result.data).map { |row| MetaInsightsRowSerializer.serialize(row, conteudo) }
          end

          def accounts
            # `business_id` é ignorado de propósito: no link público as contas
            # são as do link, independentemente da BM que o seletor da página
            # tenha em memória. Consultar por BM custaria uma chamada à Graph
            # por opção.
            render json: link_scoped_accounts
          end

          # BMs do link.
          #
          # O HTML original lista TODAS as BMs da integração e usa a lista para
          # popular o seletor de conta. Duas coisas estão em jogo:
          #
          # * segurança: devolver as BMs reais revelaria o nome de outras
          #   empresas, e a lista precisa existir, senão o seletor fica vazio;
          # * tempo: descobrir a que BM cada conta pertence exige uma chamada à
          #   Graph por BM. Com 21 BMs são ~42 requests sequenciais, a
          #   requisição morre no Rack::Timeout de 15s e a página do cliente
          #   abre em branco.
          #
          # daí UMA BM sintética, que representa exatamente o conjunto de contas
          # do link: o seletor funciona, não vaza nome de terceiro e a rota
          # responde sem tocar na Graph.
          SHARED_BUSINESS_ID = 'link'

          def business_managers
            render json: [{ 'id' => SHARED_BUSINESS_ID, 'name' => 'Contas do link' }]
          end
        end
      end
    end
  end
end