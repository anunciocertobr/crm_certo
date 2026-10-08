# Cria um contêiner do Tag Manager a partir de um dos modelos prontos e
# importa nele todo o conjunto de tags/acionadores/variáveis/templates —
# roda em background porque a cota de escrita do Google (30/min) obriga a
# pausar entre cada chamada, e um contêiner grande leva vários minutos
# (tempo longo demais pra segurar uma requisição HTTP síncrona).
class Gtm::CreateContainerFromTemplateJob < ApplicationJob
  queue_as :low

  def perform(account_id:, client_name:, usage_context:, fields:, sheet_url:)
    result = Google::TagManagerService.new.create_container_from_template(
      account_id, client_name, usage_context, fields, sheet_url
    )

    Rails.logger.error("Gtm::CreateContainerFromTemplateJob falhou pra '#{client_name}': #{result.error}") unless result.success
  end
end
