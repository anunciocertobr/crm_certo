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

      # `hook_id` escolhe UMA conta Helena específica entre várias
      # conectadas (ver apps.yml, allow_multiple_hooks) — pedido do
      # usuário pra conectar mais de uma conta e escolher qual ver na aba
      # Externo de Rastreamentos. Sem `hook_id`, cai no comportamento
      # antigo (`find_by`, primeira conta encontrada) — mantém compatível
      # pra quem só tem uma conta e nunca precisou escolher.
      def initialize(token: nil, hook_id: nil)
        hook = hook_id.present? ? Integrations::Hook.find_by(id: hook_id, app_id: "helena") : Integrations::Hook.find_by(app_id: "helena")
        @token = token ||
                 ENV["HELENA_WTS_TOKEN"] ||
                 Rails.application.credentials.dig(:helena_wts, :token) ||
                 hook&.settings&.dig("token")
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
