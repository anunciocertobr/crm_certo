# frozen_string_literal: true

# Recebe os arquivos de um CLIENTE via link copiável (aba "Solicitar Criativo"
# da página Criação Meta). Público de propósito: o link carrega um segredo
# único (grant) gerado pela dashboard e enviado ao cliente — quem tiver o link
# pode submeter os arquivos, que caem na pasta de destino (Drive ou Dropbox)
# amarrada a esse grant. Sem sessão e sem API key — mesmo padrão dos painéis
# públicos anônimos e do MetaClient::GrantsController.
class Public::Api::V1::MetaClient::CriativosController < PublicController
  # GET /public/api/v1/meta_client/criativos/:grant
  # Valida o link no navegador do cliente (a página do gestor consulta antes
  # de liberar o envio) e devolve o nome/pasta de destino pro cliente ver.
  def show
    result = Meta::SolicitarCriativoService.grant_info(params[:grant])

    if result.success
      render json: { success: true, data: result.data }
    else
      render json: { success: false, error: result.error }, status: :not_found
    end
  end

  # POST /public/api/v1/meta_client/criativos
  # body (multipart): { grant, campos: '{...json...}' , arquivos: [file,...] }
  def create
    campos = parse_campos(params[:campos])

    result = Meta::SolicitarCriativoService.receber_submissao(
      grant: params[:grant],
      campos: campos,
      arquivos: params[:arquivos]
    )

    if result.success
      render json: { success: true, data: result.data }
    else
      render json: { success: false, error: result.error }, status: :unprocessable_entity
    end
  end

  private

  def parse_campos(raw)
    return {} if raw.blank?

    parsed = JSON.parse(raw.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end