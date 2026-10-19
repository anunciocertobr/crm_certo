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
          content: template
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
        push_entity_line(lines, 'Campanha', @submission.campaign_name, @submission.campaign_id)
        push_entity_line(lines, 'Conjunto', @submission.adset_name, @submission.adset_id)
        push_entity_line(lines, 'Anúncio', @submission.ad_name, @submission.ad_id)

        criativo = creative_lines
        unless criativo.empty?
          lines << ''
          lines << '*Criativo:*'
          lines.concat(criativo)
        end

        alvo = targeting_lines
        unless alvo.empty?
          lines << ''
          lines << '*Direcionamento do anúncio:*'
          lines.concat(alvo)
        end

        lines << ''
        lines << '*Respostas:*'
        Array(@submission.field_data).each do |f|
          name = f['name'].to_s.tr('_', ' ').capitalize
          value = Array(f['values']).first
          lines << "• #{name}: #{value}" if value.present?
        end
        lines.join("\n")
      end

      # Nome + ID entre parênteses — o ID é o que permite achar o item no
      # Gerenciador de Anúncios quando o nome é genérico ("Novo anúncio").
      def push_entity_line(lines, label, name, id)
        return if name.blank? && id.blank?

        texto = name.presence || id
        texto = "#{texto} (#{id})" if name.present? && id.present? && id.to_s != name.to_s
        lines << "*#{label}:* #{texto}"
      end

      # Texto principal/título/descrição do anúncio que gerou o lead — vem da
      # mesma leitura de criativo já usada pra anexar a imagem (nada aqui
      # pode quebrar a notificação: sem criativo, a mensagem vai sem bloco).
      def creative_lines
        detalhes = creative_details
        return [] if detalhes.blank?

        lines = []
        lines << "• Texto principal: #{detalhes['texto_principal']}" if detalhes['texto_principal'].present?
        lines << "• Título: #{detalhes['titulo']}" if detalhes['titulo'].present?
        lines << "• Descrição: #{detalhes['descricao']}" if detalhes['descricao'].present?
        lines
      end

      def targeting_lines
        alvo = targeting_summary
        return [] if alvo.blank?

        lines = []
        lines << info_line('Orçamento', alvo[:orcamento])
        lines << info_line('Idade', idade_label(alvo))
        lines << info_line('Gênero', alvo[:generos])
        lines << info_line('Local', list_label(alvo[:localizacoes]))
        lines << info_line('Público salvo', list_label(alvo[:publicos_salvos]))
        lines << info_line('Público personalizado', list_label(alvo[:publicos_personalizados]))
        lines << info_line('Público semelhante', list_label(alvo[:publicos_semelhantes]))
        lines << info_line('Direcionamento', list_label(alvo[:direcionamento]))
        lines << info_line('Posicionamento', list_label(alvo[:posicionamento]))
        lines << info_line('Dispositivo', list_label(alvo[:dispositivos]))
        lines.compact
      end

      def info_line(label, value)
        return nil if value.blank?

        "• #{label}: #{value}"
      end

      def idade_label(alvo)
        return nil unless alvo[:idade_min].present? || alvo[:idade_max].present?

        "#{alvo[:idade_min] || '—'}-#{alvo[:idade_max] || '—'} anos"
      end

      def list_label(values)
        Array(values).reject(&:blank?).presence&.join(' · ')
      end

      def template
        @template ||= build_template
      end

      # 2 chamadas Graph no máximo (criativo + conjunto), cacheadas: cada
      # destino da lista recebe a mesma mensagem sem repetir consulta.
      def creative_details
        return nil if @submission.ad_id.blank?

        @creative_details ||= begin
          result = ads_service.creative_details(ad_id: @submission.ad_id)
          result.success ? result.data.first : nil
        rescue StandardError => e
          Rails.logger.error("Meta::LeadAds::WhatsappNotifierService creative_details: #{e.message}")
          nil
        end
      end

      def targeting_summary
        return nil if @submission.adset_id.blank?

        @targeting_summary ||= begin
          ads_service.adset_targeting_summary(@submission.adset_id)
        rescue StandardError => e
          Rails.logger.error("Meta::LeadAds::WhatsappNotifierService targeting_summary: #{e.message}")
          nil
        end
      end

      def ads_service
        @ads_service ||= Meta::AdsManagerService.new
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
        detalhes = creative_details
        return nil if detalhes.blank?

        detalhes['imagem'].presence || detalhes['thumbnail_url'].presence
      end
    end
  end
end
