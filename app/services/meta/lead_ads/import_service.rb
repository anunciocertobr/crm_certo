# Substitui os fluxos n8n "ellie/paiva corretora baixar leads formulario
# Meta" — o webhook `leadgen` do Meta só avisa o ID (Webhooks::FacebookController
# -> Webhooks::FacebookLeadgenEventsJob), este serviço busca o lead completo
# na Graph API (Meta::AdsManagerService#lead_detail) e decide o que fazer
# pelo MetaLeadForm do form_id encontrado:
#   - sem mapeamento, ou mode: 'pipeline' -> persiste em MetaLeadSubmission e
#     cria Contato + 1 PipelineItem por Pipeline/Estágio mapeado (ver
#     MetaLeadFormPipeline), nunca descartando um lead sem mapeamento — ele
#     fica em MetaLeadSubmission (status 'unmapped_form') até alguém mapear.
#   - mode: 'notify_only' -> só notifica por WhatsApp, nunca persiste nada
#     (nem MetaLeadSubmission, nem Contato, nem PipelineItem) — era o papel
#     do antigo Meta::LeadAds::NotifyOnlyService, hoje substituído por essa
#     escolha por formulário em vez de uma lista global de page_id.
module Meta
  module LeadAds
    class ImportService
      # Dedup do leadgen_id funciona pros dois modos (a Meta pode reenviar o
      # mesmo webhook) — pro modo 'pipeline' o índice único de leadgen_id em
      # MetaLeadSubmission já protege, mas pro 'notify_only' nada é persistido,
      # então o cache é a única defesa contra notificar duas vezes.
      DEDUP_TTL = 7.days

      PipelineTarget = Struct.new(:pipeline, :pipeline_stage)

      def self.import_from_webhook(page_id:, leadgen_id:)
        new.import_from_webhook(page_id: page_id, leadgen_id: leadgen_id)
      end

      def self.reprocess(submission)
        new.process(submission)
      end

      def import_from_webhook(page_id:, leadgen_id:)
        return if Rails.cache.exist?(dedup_cache_key(leadgen_id))
        return if MetaLeadSubmission.exists?(leadgen_id: leadgen_id)

        result = Meta::AdsManagerService.new.lead_detail(page_id: page_id, leadgen_id: leadgen_id)
        unless result.success
          Rails.logger.error("Meta::LeadAds::ImportService: falha ao buscar lead #{leadgen_id}: #{result.error}")
          return
        end

        data = result.data
        lead_form = MetaLeadForm.find_by(form_id: data['form_id'], active: true)

        if lead_form&.mode == 'notify_only'
          import_notify_only(page_id: page_id, leadgen_id: leadgen_id, data: data)
        else
          import_and_persist(page_id: page_id, leadgen_id: leadgen_id, data: data)
        end
      end

      def process(submission)
        lead_form = MetaLeadForm.find_by(form_id: submission.form_id, active: true)

        # Notificar por WhatsApp é independente do mapeamento no CRM — dispara
        # mesmo pra formulário ainda sem pipeline configurado (ver
        # Meta::LeadAds::WhatsappNotifierService sobre a resolução do destino).
        Meta::LeadAds::WhatsappNotifierService.call(submission)

        targets = pipeline_targets_for(lead_form, page_id: submission.page_id)

        if targets.empty?
          submission.update!(status: 'unmapped_form') unless submission.status == 'unmapped_form'
          return
        end

        parsed = parse_fields(submission.field_data)
        contact = find_or_create_contact(parsed)
        unless contact
          submission.update!(
            meta_lead_form: lead_form,
            status: 'error',
            error_message: 'Não foi possível identificar telefone ou e-mail nas respostas do formulário'
          )
          return
        end

        first_pipeline_item = nil
        targets.each do |target|
          existing_item = target.pipeline.pipeline_items.find_by(contact: contact, completed_at: nil)
          pipeline_item = existing_item || target.pipeline.add_contact(contact, target.pipeline_stage, nil)
          first_pipeline_item ||= pipeline_item

          # Primeiro evento do funil pro "Conversion Leads" da Meta (ver
          # Meta::ConversionsApiCrmService) — só no card novo de verdade, não
          # quando reaproveita um já existente (senão reenviaria "Lead" toda
          # vez que a mesma pessoa manda outro formulário).
          Meta::SendCrmLeadStatusJob.perform_later(pipeline_item.id, event_name: 'Lead') if existing_item.nil?
        end

        submission.update!(
          meta_lead_form: lead_form,
          contact: contact,
          pipeline_item: first_pipeline_item,
          status: 'processed',
          error_message: nil
        )
      rescue StandardError => e
        Rails.logger.error("Meta::LeadAds::ImportService: #{e.message}")
        submission.update(status: 'error', error_message: e.message)
      end

      private

      def import_and_persist(page_id:, leadgen_id:, data:)
        submission = MetaLeadSubmission.create!(
          leadgen_id: leadgen_id,
          page_id: page_id,
          form_id: data['form_id'],
          ad_id: data['ad_id'],
          adset_id: data['adset_id'],
          campaign_id: data['campaign_id'],
          ad_name: data['ad_name'],
          adset_name: data['adset_name'],
          campaign_name: data['campaign_name'],
          field_data: data['field_data'] || [],
          lead_created_time: data['created_time']
        )
        process(submission)
        Rails.cache.write(dedup_cache_key(leadgen_id), true, expires_in: DEDUP_TTL)
      rescue ActiveRecord::RecordNotUnique
        # Webhook reenviado entre o check de dedup e o create! (corrida rara)
        # — já existe/já está sendo processado, nada a fazer.
        nil
      end

      # Objeto em memória só pra alimentar o WhatsappNotifierService (que lê
      # field_data/ad_id/adset_id/form_id e o nome do formulário) — nunca é
      # salvo, igual o antigo Meta::LeadAds::NotifyOnlyService#build_submission.
      def import_notify_only(page_id:, leadgen_id:, data:)
        submission = MetaLeadSubmission.new(
          leadgen_id: leadgen_id,
          page_id: page_id,
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
        result = Meta::LeadAds::WhatsappNotifierService.call(submission)
        if result.success
          Rails.cache.write(dedup_cache_key(leadgen_id), true, expires_in: DEDUP_TTL)
        else
          Rails.logger.error("Meta::LeadAds::ImportService: notificação (notify_only) #{leadgen_id} falhou: #{result.error}")
        end
      end

      def dedup_cache_key(leadgen_id)
        "meta_lead_import:#{leadgen_id}"
      end

      # União dos pipelines da Página (MetaLeadPageSetting) com os do
      # formulário (MetaLeadFormPipeline) — nunca sobrescrita, um lead pode
      # cair nos dois ao mesmo tempo, dedupicado por par Pipeline+Estágio
      # igual. Exceção: mode: 'notify_only' é a escolha explícita de nunca
      # criar card pra esse formulário — ignora o padrão da página também
      # (senão configurar um pipeline pra página reativaria card em todo
      # formulário marcado notify_only de propósito).
      def pipeline_targets_for(lead_form, page_id:)
        return [] if lead_form&.mode == 'notify_only'

        form_targets = lead_form ? lead_form.meta_lead_form_pipelines.includes(:pipeline, :pipeline_stage) : []
        page_targets = MetaLeadPageSetting.find_by(page_id: page_id)&.meta_lead_page_pipelines&.includes(:pipeline, :pipeline_stage) || []

        combined = (page_targets.to_a + form_targets.to_a)
                   .uniq { |p| [p.pipeline_id, p.pipeline_stage_id] }
                   .map { |p| PipelineTarget.new(p.pipeline, p.pipeline_stage) }
        return combined if combined.any?

        pipeline, stage = default_pipeline_and_stage
        pipeline && stage ? [PipelineTarget.new(pipeline, stage)] : []
      end

      # Padrão da conta (Configurações > Admin, tipo 'meta_leads_pipeline_default')
      # pra formulário sem MetaLeadForm próprio — evita que o lead fique preso
      # em 'unmapped_form' pra sempre só porque ninguém mapeou aquele
      # formulário específico ainda. `nil, nil` quando não configurado (os
      # dois IDs têm que existir e resolver pra registro de verdade; config
      # pela metade não cria pipeline_item num lugar errado).
      def default_pipeline_and_stage
        pipeline_id = GlobalConfigService.load('META_LEADS_PIPELINE_ID', nil)
        stage_id = GlobalConfigService.load('META_LEADS_STAGE_ID', nil)
        return [nil, nil] if pipeline_id.blank? || stage_id.blank?

        pipeline = Pipeline.find_by(id: pipeline_id)
        stage = pipeline&.pipeline_stages&.find_by(id: stage_id)
        [pipeline, stage]
      end

      # Pergunta de telefone CUSTOM no formulário (texto livre, ex. "Qual seu
      # WhatsApp?") costuma vir só com DDD+número, sem +55 — diferente do
      # campo padrão "Número de telefone" da Meta, que já vem em E.164.
      # Mesma convenção já usada em Marketing::WhatsappNotifierService e
      # DigitalMenu::OrderNotificationService: assume Brasil quando faltar
      # o código do país.
      def normalize_br_phone(raw)
        digits = raw.to_s.gsub(/\D/, '')
        digits.start_with?('55') ? digits : "55#{digits}"
      end

      def parse_fields(field_data)
        Meta::LeadAds::FieldParser.parse(field_data)
      end

      def find_or_create_contact(parsed)
        phone = Whatsapp::PhoneNumberNormalizer.to_e164(normalize_br_phone(parsed[:phone])) if parsed[:phone].present?
        email = parsed[:email].presence
        return nil if phone.blank? && email.blank?

        contact = Contact.find_by(phone_number: phone) if phone.present?
        contact ||= Contact.find_by(email: email) if email.present?
        return contact if contact

        Contact.create!(
          type: 'person',
          name: parsed[:name].presence || 'Lead Meta Ads',
          phone_number: phone,
          email: email,
          additional_attributes: { 'lead_source' => 'meta_lead_ads' }
        )
      end
    end
  end
end
