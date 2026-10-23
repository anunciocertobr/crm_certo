# Manda (e responde) mensagens de confirmação de ServiceInvoiceSchedule nos
# canais WhatsApp/Telegram — reaproveita a mesma infraestrutura de contato/
# conversa/mensagem do resto do CRM (ContactInboxWithContactBuilder +
# ConversationBuilder + Message com content_type 'input_select' pros
# botões), igual Marketing::WhatsappNotifierService já fazia pros alertas
# de marketing. O canal 'notification' (sino interno) não passa por aqui —
# ver ServiceInvoices::ScheduleNotificationJob.
#
# Qual inbox usar em cada canal vem de GlobalConfig (mesmo padrão de
# MARKETING_ALERTS_INBOX_ID): NFSE_SCHEDULE_WHATSAPP_INBOX_ID /
# NFSE_SCHEDULE_TELEGRAM_INBOX_ID — configurar uma vez, vale pra todos os
# agendamentos.
module ServiceInvoices
  class ScheduleNotifierService
    CONTACT_NAME = 'Confirmação de NFS-e agendada'

    def self.notify!(confirmation)
      new(confirmation).notify!
    end

    def self.reply!(confirmation, channel, text, buttons: nil)
      new(confirmation).send_to_channel(channel, text, buttons: buttons)
    end

    def self.resumo_texto(confirmation, prefixo: nil)
      new(confirmation).resumo_texto(prefixo: prefixo)
    end

    def initialize(confirmation)
      @confirmation = confirmation
      @schedule = confirmation.service_invoice_schedule
    end

    def notify!
      texto = resumo_texto
      botoes = [{ title: 'Confirmar', value: 'confirmar' }, { title: 'Recusar', value: 'recusar' },
                { title: 'Editar', value: 'editar' }]

      conversation_ids = {}
      Array(@schedule.channels).each do |channel|
        next unless %w[whatsapp telegram].include?(channel)

        conversation = find_or_build_conversation(channel)
        next unless conversation

        conversation_ids[channel] = conversation.id
        create_message(conversation, texto, botoes)
      end

      @confirmation.update!(status: 'notified', notified_at: Time.current, conversation_ids: conversation_ids)
    end

    def send_to_channel(channel, text, buttons: nil)
      conversation_id = @confirmation.conversation_ids[channel]
      conversation = Conversation.find_by(id: conversation_id)
      return unless conversation

      create_message(conversation, text, buttons)
    end

    def resumo_texto(prefixo: nil)
      attrs = @confirmation.full_invoice_attrs
      linhas = [
        prefixo || "📄 NFS-e agendada pra #{@confirmation.scheduled_for.strftime('%d/%m/%Y')} — confirma a emissão?",
        '',
        "Tomador: #{attrs[:tomador_nome]} (#{attrs[:tomador_cpf_cnpj]})",
        "Valor: R$ #{format('%.2f', attrs[:valor_servicos].to_f)}",
        "Descrição: #{attrs[:discriminacao]}",
        "Código de serviço: #{attrs[:codigo_servico_municipal]}"
      ]
      linhas.join("\n")
    end

    private

    def find_or_build_conversation(channel)
      inbox = Inbox.find_by(id: inbox_id_for(channel))
      return nil unless inbox

      contact_attributes, source_id = contact_params_for(channel)
      return nil if contact_attributes.nil?

      contact_inbox = ContactInboxWithContactBuilder.new(
        inbox: inbox, contact_attributes: contact_attributes, source_id: source_id
      ).perform
      return nil unless contact_inbox

      params = ActionController::Parameters.new(
        custom_attributes: { nfse_confirmation_id: @confirmation.id },
        additional_attributes: channel == 'telegram' ? { chat_id: @schedule.notify_telegram_chat_id } : {}
      ).permit!

      ConversationBuilder.new(params: params, contact_inbox: contact_inbox).perform
    end

    def inbox_id_for(channel)
      key = channel == 'whatsapp' ? 'NFSE_SCHEDULE_WHATSAPP_INBOX_ID' : 'NFSE_SCHEDULE_TELEGRAM_INBOX_ID'
      GlobalConfigService.load(key, nil)
    end

    # source_id identifica o contato dentro do canal: telefone no WhatsApp,
    # chat_id no Telegram (o bot só consegue mandar mensagem pra quem já deu
    # /start nele antes — não dá pra iniciar conversa com alguém que nunca
    # falou com o bot, limitação da própria API do Telegram).
    def contact_params_for(channel)
      case channel
      when 'whatsapp'
        return [nil, nil] if @schedule.notify_whatsapp_number.blank?

        # Mesmo padrão de Marketing::WhatsappNotifierService (já comprovado
        # em produção): não passa source_id — o builder resolve pelo
        # phone_number pra canais WhatsApp.
        phone = normalize_phone(@schedule.notify_whatsapp_number)
        [{ phone_number: phone, name: CONTACT_NAME }, nil]
      when 'telegram'
        return [nil, nil] if @schedule.notify_telegram_chat_id.blank?

        # Diferente do WhatsApp: aqui source_id = chat_id é necessário pra
        # correlacionar a resposta que chegar depois pelo webhook do
        # Telegram com esta mesma ContactInbox/conversa — não testado ao
        # vivo ainda, validar no primeiro agendamento real.
        chat_id = @schedule.notify_telegram_chat_id
        [{ name: CONTACT_NAME, identifier: chat_id }, chat_id]
      end
    end

    def normalize_phone(phone)
      digits = phone.to_s.gsub(/\D/, '')
      digits = "55#{digits}" unless digits.start_with?('55')
      "+#{digits}"
    end

    def create_message(conversation, text, buttons)
      attrs = { inbox_id: conversation.inbox_id, message_type: :outgoing, content: text }
      if buttons.present?
        attrs[:content_type] = 'input_select'
        attrs[:content_attributes] = { items: buttons }
      end
      conversation.messages.create!(attrs)
    end
  end
end
