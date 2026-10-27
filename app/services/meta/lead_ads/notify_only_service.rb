module Meta
  module LeadAds
    # OBSOLETO (27/10/2026): substituído por MetaLeadForm#mode == 'notify_only',
    # que faz a mesma coisa (ver Meta::LeadAds::ImportService#import_notify_only)
    # mas escolhido por FORMULÁRIO em vez de uma lista global de page_id — a
    # escolha por página inteira não permitia dois formulários da mesma página
    # terem comportamentos diferentes. Mantido só como referência/fallback
    # manual; Webhooks::FacebookLeadgenEventsJob não chama mais esta classe.
    # Antes de apagar de vez: confirmar que nenhum form_id ainda depende só da
    # config antiga (META_LEADS_NOTIFY_ONLY_PAGE_IDS) — migrar pra um
    # MetaLeadForm com mode: 'notify_only' primeiro.
    #
    # Caminho "só notificar": busca o lead na Graph API e manda pro WhatsApp
    # configurado em MetaLeadNotificationSetting/GlobalConfig, sem criar
    # MetaLeadSubmission, Contact de lead ou PipelineItem. Usado pelos webhooks
    # das páginas listadas em META_LEADS_NOTIFY_ONLY_PAGE_IDS quando
    # META_LEADS_NOTIFY_ONLY=true (ver Webhooks::FacebookLeadgenEventsJob).
    #
    # A deduplicação é no Rails.cache (Redis), não no banco: a Meta pode
    # reenviar o mesmo leadgen_id e não queremos duas mensagens. A mensagem
    # enviada em si continua sendo registrada na conversa do inbox de destino
    # (infraestrutura normal de WhatsApp do CRM) — o que não é gravado é o lead.
    class NotifyOnlyService
      CACHE_TTL = 7.days

      Result = Struct.new(:success, :error, keyword_init: true)

      def self.enabled_for?(page_id)
        enabled = ActiveModel::Type::Boolean.new.cast(GlobalConfigService.load('META_LEADS_NOTIFY_ONLY', false))
        return false unless enabled

        # Lista vazia = ninguém (não deixa o modo ligar sem escopo de página).
        allowed = GlobalConfigService.load('META_LEADS_NOTIFY_ONLY_PAGE_IDS', nil).to_s
                                                                                 .split(',').map(&:strip).reject(&:blank?)
        allowed.include?(page_id.to_s)
      end

      def self.call(page_id:, leadgen_id:)
        new(page_id: page_id, leadgen_id: leadgen_id).call
      end

      def initialize(page_id:, leadgen_id:)
        @page_id = page_id
        @leadgen_id = leadgen_id
      end

      def call
        return Result.new(success: true, error: 'already_notified') if Rails.cache.exist?(cache_key)
        return Result.new(success: true, error: 'already_notified') if already_notified_in_db?

        detail = Meta::AdsManagerService.new.lead_detail(page_id: @page_id, leadgen_id: @leadgen_id)
        unless detail.success
          Rails.logger.error("Meta::LeadAds::NotifyOnlyService: lead_detail #{@leadgen_id} falhou: #{detail.error}")
          return Result.new(success: false, error: detail.error)
        end

        submission = build_submission(detail.data)
        notification = Meta::LeadAds::WhatsappNotifierService.call(submission)

        if notification.success
          Rails.cache.write(cache_key, true, expires_in: CACHE_TTL)
          Rails.logger.info("Meta::LeadAds::NotifyOnlyService: lead #{@leadgen_id} (página #{@page_id}) notificado sem persistir.")
        else
          Rails.logger.error("Meta::LeadAds::NotifyOnlyService: notificação #{@leadgen_id} falhou: #{notification.error}")
        end

        notification
      end

      private

      # Objeto em memória só pra alimentar o WhatsappNotifierService (que lê
      # field_data/ad_id/adset_id/form_id e o nome do formulário). Nunca é salvo.
      def build_submission(data)
        MetaLeadSubmission.new(
          leadgen_id: @leadgen_id,
          page_id: @page_id,
          form_id: data['form_id'],
          ad_id: data['ad_id'],
          adset_id: data['adset_id'],
          campaign_id: data['campaign_id'],
          ad_name: data['ad_name'],
          adset_name: data['adset_name'],
          campaign_name: data['campaign_name'],
          field_data: data['field_data'] || [],
          lead_created_time: data['created_time'],
          status: 'processed'
        )
      end

      # Leads que já passaram pelo ImportService (antes do modo só-notificar)
      # não devem ser notificados de novo se a Meta reenviar o webhook.
      def already_notified_in_db?
        MetaLeadSubmission.where(leadgen_id: @leadgen_id).where.not(notified_whatsapp_at: nil).exists?
      end

      def cache_key
        "meta_lead_notify_only:#{@leadgen_id}"
      end
    end
  end
end
