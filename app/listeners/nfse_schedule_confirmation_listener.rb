# Escuta mensagem incoming em QUALQUER conversa marcada com
# custom_attributes['nfse_confirmation_id'] (criada por
# ServiceInvoices::ScheduleNotifierService) e repassa o texto pro model
# decidir o que fazer (confirmar/recusar/editar) — ver
# ServiceInvoiceScheduleConfirmation#process_reply!.
#
# Listener próprio (não AgentBotListener nem AutomationRule) porque: roda
# in-process sem round-trip HTTP, não depende de bot conectado na inbox, e
# o "payload" de verdade (clique de botão) chega só como texto do título do
# botão — não tem id estruturado pra casar via Automation Rule.
class NfseScheduleConfirmationListener < BaseListener
  def message_created(event)
    message = extract_message_and_account(event)[0]
    return unless message&.incoming?

    conversation = message.conversation
    return if conversation.nil?

    confirmation_id = conversation.custom_attributes&.dig('nfse_confirmation_id')
    return if confirmation_id.blank?

    confirmation = ServiceInvoiceScheduleConfirmation.find_by(id: confirmation_id)
    return if confirmation.nil?

    channel = canal_da_conversa(confirmation, conversation.id)
    return if channel.nil?

    confirmation.process_reply!(channel, message.content.to_s)
  rescue StandardError => e
    Rails.logger.error "[NfseScheduleConfirmation] #{e.message}"
  end

  private

  def canal_da_conversa(confirmation, conversation_id)
    confirmation.conversation_ids.find { |_canal, id| id.to_s == conversation_id.to_s }&.first
  end
end
