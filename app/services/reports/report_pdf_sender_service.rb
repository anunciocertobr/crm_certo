# Manda um PDF qualquer (bytes já prontos — relatório gerado no navegador,
# NFS-e já emitida, etc.) por WhatsApp pra um destino (inbox + número OU
# inbox + grupo). Reaproveita o mesmo padrão de
# Meta::LeadAds::WhatsappNotifierService#send_to (ContactInboxWithContact
# Builder + ConversationBuilder) e o pipeline de envio já existente
# (Message#send_reply -> SendReplyJob -> provider dispatch) — nenhum
# código novo de envio. Apesar do namespace `Reports::`, não é mais
# exclusivo de relatórios (ver `contact_name:`, que cada chamador passa
# pra descrever o tipo de arquivo no nome do contato criado).
#
# Restrição importante (mesma de AgentBots::RemoteMediaAttacher): o anexo
# tem que ser montado no Message ANTES do save — commitar sem anexo
# dispara o envio como texto puro na hora, e anexar depois não reenvia.
module Reports
  class ReportPdfSenderService
    Result = Struct.new(:success, :error, keyword_init: true)

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(pdf_bytes:, filename:, inbox_id:, whatsapp_number: nil, group_jid: nil, group_name: nil,
                   created_by: nil, contact_name: 'Relatório Meta Ads')
      @pdf_bytes = pdf_bytes
      @filename = filename
      @inbox_id = inbox_id
      @whatsapp_number = whatsapp_number
      @group_jid = group_jid
      @group_name = group_name
      @created_by = created_by
      @contact_name = contact_name
    end

    def call
      inbox = Inbox.find_by(id: @inbox_id)
      return Result.new(success: false, error: "inbox não encontrada (#{@inbox_id})") unless inbox

      contact_inbox, conversation_params = destination_contact_inbox(inbox)
      return Result.new(success: false, error: 'destino inválido (sem número nem grupo)') unless contact_inbox

      conversation = ConversationBuilder.new(params: conversation_params, contact_inbox: contact_inbox).perform
      message = conversation.messages.new(inbox_id: conversation.inbox_id, message_type: :outgoing, content: nil)
      message.attachments.new(
        file_type: 'file',
        file: { io: StringIO.new(@pdf_bytes), filename: @filename, content_type: 'application/pdf' }
      )
      message.save!

      Result.new(success: true)
    rescue StandardError => e
      Rails.logger.error("[Reports::ReportPdfSenderService] #{e.class}: #{e.message}")
      Result.new(success: false, error: e.message)
    end

    private

    def destination_contact_inbox(inbox)
      if @group_jid.present?
        contact_inbox = ContactInboxWithContactBuilder.new(
          inbox: inbox,
          source_id: @group_jid,
          contact_attributes: { identifier: @group_jid, type: 'group', name: @group_name.presence || 'Grupo WhatsApp' }
        ).perform
        params = ActionController::Parameters.new(additional_attributes: { evolution_chat_id: @group_jid }).permit!
        [contact_inbox, params]
      elsif @whatsapp_number.present?
        contact_inbox = ContactInboxWithContactBuilder.new(
          inbox: inbox,
          contact_attributes: { phone_number: normalize_phone(@whatsapp_number), name: @contact_name }
        ).perform
        [contact_inbox, ActionController::Parameters.new({}).permit!]
      else
        [nil, nil]
      end
    end

    # Mesmo padrão de Meta::LeadAds::WhatsappNotifierService#normalize_phone.
    def normalize_phone(raw)
      digits = raw.to_s.gsub(/\D/, '')
      digits = "55#{digits}" unless digits.start_with?('55')
      "+#{digits}"
    end
  end
end
