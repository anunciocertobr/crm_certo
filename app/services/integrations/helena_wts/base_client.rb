module Integrations
  module HelenaWts
    # Token lido em ordem: kwarg explícito, ENV, Rails credentials, e por
    # último o Integrations::Hook(app_id: 'helena') criado pela tela
    # Configurações > Integrações > card "Helena (WTS)" — mesmo padrão que
    # BMS/LeadSquared usam pra guardar a API key colada pelo usuário
    # (ver Crm::Bms::ProcessorService#initialize, hook.settings['api_key']).
    class BaseClient
      include HTTParty

      base_uri "https://api.wts.chat"

      def initialize(token: nil)
        @token = token ||
                 ENV["HELENA_WTS_TOKEN"] ||
                 Rails.application.credentials.dig(:helena_wts, :token) ||
                 Integrations::Hook.find_by(app_id: "helena")&.settings&.dig("token")
        raise "Helena/WTS token missing" if @token.blank?
      end

      def get(path, params = {})
        self.class.get(path, headers: headers, query: params)
      end

      private

      def headers
        {
          "Authorization" => "Bearer #{@token}",
          "Accept" => "application/json"
        }
      end
    end
  end
end
