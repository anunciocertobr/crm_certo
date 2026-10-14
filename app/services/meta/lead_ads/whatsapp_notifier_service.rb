# Avisa por WhatsApp quando um lead novo chega de um formulário Meta (Lead
# Ads) — texto com formulário/data/respostas + a imagem do criativo do
# anúncio que gerou o lead, quando disponível. Reaproveita a mesma
# infraestrutura de contato/conversa/mensagem usada pelo resto do CRM
# (ContactInboxWithContactBuilder + ConversationBuilder, mesmo padrão de
# Marketing::WhatsappNotifierService / DigitalMenu::OrderNotificationService),
# então o envio passa pelos providers já existentes (Evolution/Z-API/Cloud/
# etc) sem reinventar a integração com WhatsApp.
#
# Resolução dos destinos (pode ser mais de um canal/número — botão "+" no
# front), nessa ordem:
#   1. MetaLeadNotificationSetting do form_id, se existir e enabled=true.
#   2. Padrão da conta (GlobalConfigService, config 'meta_leads_notify').
#   3. Nenhum dos dois configurado/habilitado -> não notifica (not_configured).
# MetaLeadNotificationSetting com enabled=false é opt-out explícito: não cai
# pro padrão da conta, mesmo que ele exista.
module Meta
  module LeadAds
    class WhatsappNotifierService
      Result = Struct.new(:success, :error, keyword_init: true)

      def self.call(submission)
        new(submission).call
      end

      def initialize(submission)
        @submission = submission
      end

      # Envia pra cada canal configurado; cada um falha isoladamente (um
      # número errado não deve impedir os outros de receber). success=true
      # se pelo menos um canal recebeu; errors traz o motivo de cada falha.
      def call
        return Result.new(success: true) if @submission.notified_whatsapp_at.present? # já notificado (reprocess)

        destinations = resolve_destinations
        return Result.new(success: false, error: 'not_configured') if destinations.empty?

        errors = []
        sent = false
        destinations.each do |inbox_id, target_phone|
          send_to(inbox_id, target_phone)
          sent = true
        rescue StandardError => e
          errors << "#{target_phone}: #{e.message}"
        end

        if sent
          @submission.update!(notified_whatsapp_at: Time.current)
          Result.new(success: true, error: errors.presence&.join('; '))
        else
          Result.new(success: false, error: errors.join('; '))
        end
      rescue StandardError => e
        Rails.logger.error("Meta::LeadAds::WhatsappNotifierService failed: #{e.class}: #{e.message}")
        Result.new(success: false, error: e.message)
      end

      private

      def send_to(inbox_id, target_phone)
        inbox = Inbox.find_by(id: inbox_id)
        raise "inbox_not_found(#{inbox_id})" unless inbox

        contact_inbox = ContactInboxWithContactBuilder.new(
          inbox: inbox,
          contact_attributes: { phone_number: normalize_phone(target_phone), name: contact_name }
        ).perform
        raise 'contact_error' unless contact_inbox

        conversation = ConversationBuilder.new(
          params: ActionController::Parameters.new({}).permit!,
          contact_inbox: contact_inbox
        ).perform

        message = conversation.messages.new(
          inbox_id: conversation.inbox_id,
          message_type: :outgoing,
          content: build_template
        )
        image_url = creative_image_url
        AgentBots::RemoteMediaAttacher.build_attachments(message, [{ url: image_url, file_type: 'image' }]) if image_url.present?
        message.save!
      end

      # Devolve [[inbox_id, whatsapp_number], ...] — nunca um par só por
      # suposição: se enabled=true mas a lista de canais está vazia, não cai
      # silenciosamente pro padrão da conta (seria notificar no lugar errado).
      def resolve_destinations
        setting = MetaLeadNotificationSetting.find_by(form_id: @submission.form_id)
        return [] if setting && !setting.enabled

        if setting&.enabled
          channels = setting.effective_channels
          return channels.filter_map { |c| [c['inbox_id'], c['whatsapp_number']] if c['inbox_id'].present? && c['whatsapp_number'].present? }
        end

        return [] unless account_default_enabled?

        account_default_channels
      end

      def account_default_channels
        raw = GlobalConfigService.load('META_LEADS_NOTIFY_CHANNELS', nil)
        if raw.present?
          parsed = JSON.parse(raw) rescue [] # rubocop:disable Style/RescueModifier -- config legível por humanos no admin, JSON inválido não deve derrubar a notificação
          return Array(parsed).filter_map { |c| [c['inbox_id'], c['whatsapp_number']] if c['inbox_id'].present? && c['whatsapp_number'].present? }
        end

        # Fallback: quem configurou antes de META_LEADS_NOTIFY_CHANNELS existir.
        legacy_inbox = GlobalConfigService.load('META_LEADS_NOTIFY_INBOX_ID', nil)
        legacy_phone = GlobalConfigService.load('META_LEADS_NOTIFY_WHATSAPP_NUMBER', nil)
        return [] if legacy_inbox.blank? || legacy_phone.blank?

        [[legacy_inbox, legacy_phone]]
      end

      def account_default_enabled?
        ActiveModel::Type::Boolean.new.cast(GlobalConfigService.load('META_LEADS_NOTIFY_ENABLED', false))
      end

      def contact_name
        form_name = @submission.meta_lead_form&.form_name.presence || 'Formulário Meta'
        "Leads - #{form_name}"
      end

      def normalize_phone(phone)
        digits = phone.to_s.gsub(/\D/, '')
        digits = "55#{digits}" unless digits.start_with?('55')
        "+#{digits}"
      end

      def build_template
        lines = []
        lines << '🔔 *Novo lead — Meta Ads*'
        lines << ''
        lines << "*Formulário:* #{form_label}"
        lines << "*Data:* #{formatted_date}"
        lines << "*Campanha:* #{@submission.campaign_name}" if @submission.campaign_name.present?
        lines << "*Anúncio:* #{@submission.ad_name}" if @submission.ad_name.present?
        lines << ''
        lines << '*Respostas:*'
        Array(@submission.field_data).each do |f|
          name = f['name'].to_s.tr('_', ' ').capitalize
          value = Array(f['values']).first
          lines << "• #{name}: #{value}" if value.present?
        end
        lines.join("\n")
      end

      def form_label
        setting = MetaLeadNotificationSetting.find_by(form_id: @submission.form_id)
        setting&.form_name.presence || @submission.meta_lead_form&.form_name.presence || @submission.form_id
      end

      def formatted_date
        (@submission.lead_created_time || @submission.created_at).in_time_zone('America/Sao_Paulo').strftime('%d/%m/%Y %H:%M')
      end

      # Imagem do criativo do anúncio que gerou o lead — "qual foi o
      # formulário, a imagem, data e os dados" pedido explicitamente. Sem
      # ad_id (lead veio de um teste/preview, por exemplo) simplesmente não
      # anexa imagem, não é erro.
      def creative_image_url
        return nil if @submission.ad_id.blank?

        result = Meta::AdsManagerService.new.creative_details(ad_id: @submission.ad_id)
        return nil unless result.success

        result.data.first&.dig('imagem') || result.data.first&.dig('thumbnail_url')
      end
    end
  end
end
