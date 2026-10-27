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
# front):
#   1. União de MetaLeadPageSetting#channels (padrão da Página) com
#      MetaLeadNotificationSetting#effective_channels (do formulário,
#      quando enabled=true) — nunca sobrescrita, dedupicado por destino
#      exato. enabled=false no formulário é opt-out só da PARTE dele, a
#      Página continua valendo.
#   2. Só cai pro padrão da conta (GlobalConfigService, config
#      'meta_leads_notify') quando essa união der vazia.
#   3. Nenhum dos três configurado/habilitado -> não notifica (not_configured).
#
# O QUE vai na mensagem (seções) é escolhido por checkboxes no front: a
# preferência do formulário (MetaLeadNotificationSetting#content_sections)
# vence o padrão da conta (config 'meta_leads_notify' ->
# META_LEADS_NOTIFY_CONTENT); sem nenhuma, envia todas (CONTENT_SECTIONS).
module Meta
  module LeadAds
    class WhatsappNotifierService
      Result = Struct.new(:success, :error, keyword_init: true)

      # Seções que podem ser ligadas/desligadas por formulário (checkboxes no
      # front, coluna MetaLeadNotificationSetting#content_sections) ou no padrão
      # da conta (config 'meta_leads_notify' -> META_LEADS_NOTIFY_CONTENT).
      # Cabeçalho (formulário/data) é sempre enviado, não é seção. nil = todas.
      CONTENT_SECTIONS = %w[
        entities
        creative_image creative_text creative_title creative_description
        budget age_gender location audiences audience_detail
        platforms placements devices
        answers
      ].freeze

      # Subconjunto de CONTENT_SECTIONS que pertence ao bloco "Direcionamento do
      # anúncio" — usado só pra evitar a chamada Graph de targeting quando
      # nenhuma dessas seções está marcada.
      TARGETING_SECTIONS = %w[budget age_gender location audiences audience_detail platforms placements devices].freeze

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
        destinations.each do |destination|
          send_to(destination)
          sent = true
        rescue StandardError => e
          errors << "#{destination[:group_jid] || destination[:whatsapp_number]}: #{e.message}"
        end

        if sent
          # No modo "só notificar" (Meta::LeadAds::NotifyOnlyService) a submission
          # é um objeto em memória, nunca persistido — não há o que atualizar.
          @submission.update!(notified_whatsapp_at: Time.current) if @submission.persisted?
          Result.new(success: true, error: errors.presence&.join('; '))
        else
          Result.new(success: false, error: errors.join('; '))
        end
      rescue StandardError => e
        Rails.logger.error("Meta::LeadAds::WhatsappNotifierService failed: #{e.class}: #{e.message}")
        Result.new(success: false, error: e.message)
      end

      private

      def send_to(destination)
        inbox = Inbox.find_by(id: destination[:inbox_id])
        raise "inbox_not_found(#{destination[:inbox_id]})" unless inbox

        if destination[:group_jid].present?
          contact_inbox = group_contact_inbox(inbox, destination[:group_jid], destination[:group_name])
          conversation_params = ActionController::Parameters.new(
            additional_attributes: { evolution_chat_id: destination[:group_jid] }
          ).permit!
        else
          contact_inbox = ContactInboxWithContactBuilder.new(
            inbox: inbox,
            contact_attributes: { phone_number: normalize_phone(destination[:whatsapp_number]), name: contact_name }
          ).perform
          conversation_params = ActionController::Parameters.new({}).permit!
        end
        raise 'contact_error' unless contact_inbox

        conversation = ConversationBuilder.new(params: conversation_params, contact_inbox: contact_inbox).perform

        message = conversation.messages.new(
          inbox_id: conversation.inbox_id,
          message_type: :outgoing,
          content: template
        )
        image_url = creative_image_url
        AgentBots::RemoteMediaAttacher.build_attachments(message, [{ url: image_url, file_type: 'image' }]) if image_url.present?
        message.save!
      end

      # Devolve [{inbox_id:, whatsapp_number:} | {inbox_id:, group_jid:,
      # group_name:}, ...]. União dos canais da Página (MetaLeadPageSetting)
      # com os do formulário (MetaLeadNotificationSetting), nunca
      # sobrescrita — um lead pode notificar os dois ao mesmo tempo,
      # dedupicado por destino exato. `enabled: false` no formulário é opt-
      # out só da PARTE do formulário (a página continua valendo); só cai
      # pro padrão da conta quando a união dos dois níveis dá vazia —
      # mesma regra de "nunca um destino por suposição" de antes.
      def resolve_destinations
        union = (page_channel_destinations + form_channel_destinations)
                .uniq { |d| [d[:inbox_id], d[:whatsapp_number] || d[:group_jid]] }
        return union if union.any?

        return [] unless account_default_enabled?

        account_default_channels
      end

      def form_channel_destinations
        s = setting
        return [] if s.nil? || !s.enabled

        s.effective_channels.filter_map { |c| channel_destination(c) }
      end

      def page_channel_destinations
        page_setting = MetaLeadPageSetting.find_by(page_id: @submission.page_id)
        return [] unless page_setting

        Array(page_setting.channels).filter_map { |c| channel_destination(c) }
      end

      # Preferência do formulário (se configurada) tem prioridade sobre o
      # padrão da conta — mesma precedência dos destinos em resolve_destinations.
      def setting
        return @setting if defined?(@setting)

        @setting = MetaLeadNotificationSetting.find_by(form_id: @submission.form_id)
      end

      # Seções a enviar: escolha do formulário → padrão da conta → nil (todas).
      # Array explicito (inclusive []) significa "exatamente isso"; nil = todas.
      def content_sections
        return @content_sections if defined?(@content_sections)

        @content_sections = setting&.effective_content_sections || account_default_content_sections
      end

      def account_default_content_sections
        raw = GlobalConfigService.load('META_LEADS_NOTIFY_CONTENT', nil)
        return nil if raw.blank?

        parsed = JSON.parse(raw)
        parsed.is_a?(Array) ? parsed.map(&:to_s) : nil
      rescue JSON::ParserError
        nil
      end

      # Sem preferência salva (nil) libera tudo; com preferência, só o que foi
      # marcado. Desligar tudo e salvar é uma escolha válida (só o cabeçalho).
      def section?(key)
        content_sections.nil? || content_sections.include?(key.to_s)
      end

      def account_default_channels
        raw = GlobalConfigService.load('META_LEADS_NOTIFY_CHANNELS', nil)
        if raw.present?
          parsed = JSON.parse(raw) rescue [] # rubocop:disable Style/RescueModifier -- config legível por humanos no admin, JSON inválido não deve derrubar a notificação
          return Array(parsed).filter_map { |c| channel_destination(c) }
        end

        # Fallback: quem configurou antes de META_LEADS_NOTIFY_CHANNELS existir.
        legacy_inbox = GlobalConfigService.load('META_LEADS_NOTIFY_INBOX_ID', nil)
        legacy_phone = GlobalConfigService.load('META_LEADS_NOTIFY_WHATSAPP_NUMBER', nil)
        return [] if legacy_inbox.blank? || legacy_phone.blank?

        [{ inbox_id: legacy_inbox, whatsapp_number: legacy_phone }]
      end

      # Canal salvo (jsonb) pode ser destino número ou grupo — grupo tem
      # prioridade se os dois vierem preenchidos por engano.
      def channel_destination(c)
        return nil if c['inbox_id'].blank?
        return { inbox_id: c['inbox_id'], group_jid: c['group_jid'], group_name: c['group_name'] } if c['group_jid'].present?
        return { inbox_id: c['inbox_id'], whatsapp_number: c['whatsapp_number'] } if c['whatsapp_number'].present?

        nil
      end

      # Mesmo padrão usado pra mensagem recebida de um grupo (ver
      # Whatsapp::EvolutionHandlers::MessagesUpsert#set_group_contact) — aqui
      # é criado proativamente, não a partir de uma mensagem recebida.
      def group_contact_inbox(inbox, group_jid, group_name)
        ContactInboxWithContactBuilder.new(
          inbox: inbox,
          source_id: group_jid,
          contact_attributes: { identifier: group_jid, type: 'group', name: group_name.presence || 'Grupo WhatsApp' }
        ).perform
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

      # Ordem pedida pelo usuário: Data, Formulário, Respostas, depois Campanha
      # e Direcionamento; o Criativo (texto principal/título/descrição) vai por
      # último.
      def build_template
        lines = []
        lines << '🔔 *Novo lead — Meta Ads*'
        lines << ''
        lines << "*Data:* #{formatted_date}"
        lines << "*Formulário:* #{form_label}"

        lines.concat(answers_lines) if section?(:answers)

        if section?(:entities)
          entidades = []
          entidades.concat(account_lines)
          push_entity_line(entidades, 'Campanha', @submission.campaign_name, @submission.campaign_id)
          push_entity_line(entidades, 'Conjunto', @submission.adset_name, @submission.adset_id)
          push_entity_line(entidades, 'Anúncio', @submission.ad_name, @submission.ad_id)
          unless entidades.empty?
            lines << ''
            lines.concat(entidades)
          end
        end

        alvo = targeting_lines
        unless alvo.empty?
          lines << ''
          lines << '*Direcionamento do anúncio:*'
          lines.concat(alvo)
        end

        criativo = creative_lines
        unless criativo.empty?
          lines << ''
          lines << '*Criativo:*'
          lines.concat(criativo)
        end

        lines.join("\n")
      end

      def answers_lines
        linhas = ['', '*Respostas:*']
        Array(@submission.field_data).each do |f|
          name = f['name'].to_s.tr('_', ' ').capitalize
          value = Array(f['values']).first
          linhas << "• *#{name}*: #{value}" if value.present?
        end
        # Seção ligada mas sem nenhuma resposta, não deixa o título solto.
        linhas.length > 2 ? linhas : []
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
        lines << "• *Texto principal:* #{detalhes['texto_principal']}" if section?(:creative_text) && detalhes['texto_principal'].present?
        lines << "• *Título:* #{detalhes['titulo']}" if section?(:creative_title) && detalhes['titulo'].present?
        lines << "• *Descrição:* #{detalhes['descricao']}" if section?(:creative_description) && detalhes['descricao'].present?
        lines
      end

      # BM + conta de anúncios que geraram o lead, logo acima da campanha —
      # pra saber de qual conta/BM veio sem abrir o Gerenciador. Best-effort
      # (mesmo espírito do resto: nada aqui derruba a notificação).
      def account_lines
        conta = account_details
        return [] if conta.blank?

        lines = []
        lines << "*BM:* #{conta['bm']}" if conta['bm'].present?
        lines << "*Conta de anúncios:* #{conta['conta']}" if conta['conta'].present?
        lines
      end

      # account_id vem do mesmo resumo do conjunto já usado no direcionamento
      # (cache) — 1 chamada Graph a mais (conta + BM), cacheadas por instância.
      def account_details
        return @account_details if defined?(@account_details)

        @account_details = begin
          acct = targeting_summary && targeting_summary[:account_id]
          if acct.blank?
            nil
          else
            result = ads_service.account_labels(ad_account_id: acct)
            result.success ? result.data.first : nil
          end
        rescue StandardError => e
          Rails.logger.error("Meta::LeadAds::WhatsappNotifierService account_details: #{e.message}")
          nil
        end
      end

      def targeting_lines
        return [] unless targeting_sections_enabled?

        alvo = targeting_summary
        return [] if alvo.blank?

        lines = []
        lines << info_line('Orçamento', alvo[:orcamento]) if section?(:budget)
        lines << info_line('Idade', idade_label(alvo)) if section?(:age_gender)
        lines << info_line('Gênero', alvo[:generos]) if section?(:age_gender)
        lines << info_line('Local', list_label(alvo[:localizacoes])) if section?(:location)
        if section?(:audiences)
          lines << info_line('Público salvo', list_label(alvo[:publicos_salvos]))
          lines << info_line('Público personalizado', list_label(alvo[:publicos_personalizados]))
          lines << info_line('Público semelhante', list_label(alvo[:publicos_semelhantes]))
        end
        lines << info_line('Direcionamento', list_label(alvo[:direcionamento])) if section?(:audience_detail)
        lines << info_line('Plataformas', platform_label(alvo)) if section?(:platforms)
        lines << info_line('Posicionamento', placements_label(alvo)) if section?(:placements)
        lines << info_line('Dispositivo', list_label(alvo[:dispositivos])) if section?(:devices)
        lines.compact
      end

      def targeting_sections_enabled?
        content_sections.nil? || TARGETING_SECTIONS.any? { |s| content_sections.include?(s) }
      end

      # `publisher_platforms` ausente = posicionamentos automáticos (Advantage+),
      # que a UI do Gerenciador mostra como "Posicionamentos automáticos" — sem
      # isso a linha simplesmente sumia e parecia que faltava dado.
      def platform_label(alvo)
        plataformas = Array(alvo[:plataformas])
        return 'Automática (Advantage+)' if plataformas.empty?

        plataformas.map { |p| Meta::AdsManagerService::PLACEMENT_PLATFORM_LABELS[p] || p.to_s.tr('_', ' ').capitalize }.join(', ')
      end

      # Posicionamentos por plataforma; vazio = automáticos (Advantage+), que é
      # como o Gerenciador de Anúncios mostra o conjunto. Antes a linha sumia
      # e parecia dado faltando.
      def placements_label(alvo)
        list_label(alvo[:posicionamento]) || 'Automático (Advantage+)'
      end

      def info_line(label, value)
        return nil if value.blank?

        "• *#{label}*: #{value}"
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
        nome = setting&.form_name.presence || @submission.meta_lead_form&.form_name.presence
        return nome if nome

        # Sem configuração própria e sem form mapeado no CRM, busca o nome
        # direto na Graph — sem isso o cabeçalho saía com o ID cru do
        # formulário, que não diz nada pra quem lê a notificação.
        (leadgen_form_name_from_graph.presence || @submission.form_id).to_s
      end

      def leadgen_form_name_from_graph
        return @leadgen_form_name_from_graph if defined?(@leadgen_form_name_from_graph)

        @leadgen_form_name_from_graph = begin
          ads_service.leadgen_form_name(page_id: @submission.page_id, form_id: @submission.form_id)
        rescue StandardError => e
          Rails.logger.error("Meta::LeadAds::WhatsappNotifierService form_name: #{e.message}")
          nil
        end
      end

      def formatted_date
        (@submission.lead_created_time || @submission.created_at).in_time_zone('America/Sao_Paulo').strftime('%d/%m/%Y %H:%M')
      end

      # Imagem do criativo do anúncio que gerou o lead — "qual foi o
      # formulário, a imagem, data e os dados" pedido explicitamente. Sem
      # ad_id (lead veio de um teste/preview, por exemplo) simplesmente não
      # anexa imagem, não é erro.
      def creative_image_url
        return nil unless section?(:creative_image)

        detalhes = creative_details
        return nil if detalhes.blank?

        detalhes['imagem'].presence || detalhes['thumbnail_url'].presence
      end
    end
  end
end
