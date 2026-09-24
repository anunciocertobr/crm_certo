# frozen_string_literal: true

# Recebe o token concedido por um CLIENTE via link copiável (aba "Conceder
# Acessos" do Setup Marketing). Público de propósito: o link já carrega um
# segredo único (grant) gerado pela dashboard e enviado ao cliente — quem
# tiver o link pode autorizar a própria conta do Facebook; depois de usado,
# o link expira (Meta::ClientAccessService.aplicar_grant apaga o grant).
# Sem sessão e sem API key — mesmo padrão dos painéis públicos anônimos.
class Public::Api::V1::MetaClient::GrantsController < PublicController
  # POST /public/api/v1/meta_client/grants
  # body: { grant, fb_user_id, token }
  def create
    result = Meta::ClientAccessService.aplicar_grant(
      grant: params[:grant],
      fb_user_id: params[:fb_user_id],
      token: params[:token]
    )

    if result.success
      render json: { success: true, data: result.data }
    else
      render json: { success: false, error: result.error }, status: :unprocessable_entity
    end
  end
end