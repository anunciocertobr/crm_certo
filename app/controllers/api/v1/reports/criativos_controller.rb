# frozen_string_literal: true

# Despacha as ações da aba "Solicitar Criativo" da página Criação Meta
# (Meta::SolicitarCriativoService): status (provedores conectados), gerar link
# (público, amarrado a uma pasta de destino), listar solicitações recebidas,
# detalhe de uma solicitação (com as submissões do cliente), atualizar o status
# de uma submissão (produzindo/finalizado ou recusado) e remover um link.
class Api::V1::Reports::CriativosController < Api::V1::BaseController
  def handle
    case params[:acao]
    when 'status'
      render json: { success: true, data: [{
        'drive' => Google::DriveService.new.connected?,
        'dropbox' => Dropbox::FilesService.new.connected?
      }] }
    when 'gerar_link'
      respond Meta::SolicitarCriativoService.gerar_link(
        criado_por: Current.user&.id,
        nome: params[:nome],
        provedor: params[:provedor],
        pasta_ref: params[:pasta_ref],
        pasta_nome: params[:pasta_nome]
      )
    when 'solicitacoes'
      respond Meta::SolicitarCriativoService.solicitacoes
    when 'detalhe'
      respond Meta::SolicitarCriativoService.detalhe_solicitacao(grant: params[:grant])
    when 'atualizar_status'
      respond Meta::SolicitarCriativoService.atualizar_status(
        grant: params[:grant],
        submissao_id: params[:submissao_id],
        status: params[:status]
      )
    when 'remover_link'
      respond Meta::SolicitarCriativoService.remover_link(grant: params[:grant])
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, "Ação desconhecida: #{params[:acao]}", status: :unprocessable_entity)
    end
  end

  private

  def respond(result)
    if result.success
      render json: { success: true, data: result.data }
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, result.error, status: :unprocessable_entity)
    end
  end
end