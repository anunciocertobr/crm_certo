# Envio avulso do PDF do relatório Meta Ads por WhatsApp — botão "Enviar"
# do modal de PDF (report-pdf.v3.js). Os bytes do PDF já vêm prontos do
# navegador (jsPDF, mesma geração do "Baixar PDF"); este endpoint só
# empacota e manda, reaproveitando Reports::ReportPdfSenderService (mesmo
# serviço usado pelo envio agendado — ver Reports::MetaAdsPdfService /
# ScheduledActions::ExecutorService).
class Api::V1::Reports::MetaAdsPdfController < Api::V1::BaseController
  def send_pdf
    file = params.require(:pdf)
    result = Reports::ReportPdfSenderService.call(
      pdf_bytes: file.read,
      filename: params[:filename].presence || 'relatorio-meta-ads.pdf',
      inbox_id: params.require(:inbox_id),
      whatsapp_number: params[:whatsapp_number],
      group_jid: params[:group_jid],
      group_name: params[:group_name],
      created_by: current_user&.id
    )

    if result.success
      render json: { success: true }
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :unprocessable_entity)
    end
  end
end
