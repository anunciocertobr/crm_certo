# Substitui os fluxos n8n "ellie/paiva corretora baixar leads formulario
# Meta" — o webhook `leadgen` do Meta só avisa o ID (Webhooks::FacebookController
# -> Webhooks::FacebookLeadgenEventsJob), este serviço busca o lead completo
# na Graph API (Meta::AdsManagerService#lead_detail), resolve o
# Contato/PipelineItem via o mapeamento salvo em MetaLeadForm, e nunca
# descarta um lead sem mapeamento — ele fica em MetaLeadSubmission até
# alguém configurar o formulário em Configurações > Lead Ads (Meta).
module Meta
  module LeadAds
    class ImportService
      # Identifica telefone/e-mail/nome nas perguntas do formulário por
      # nome do campo — formulários da Meta não têm um `type` estruturado
      # pra isso, só o texto da pergunta que a corretora escolheu.
      FIELD_NAME_PATTERNS = {
        phone: /telefone|celular|whatsapp|phone/i,
        email: /e-?mail/i,
        name: /nome|name/i
      }.freeze

      def self.import_from_webhook(page_id:, leadgen_id:)
        new.import_from_webhook(page_id: page_id, leadgen_id: leadgen_id)
      end

      def self.reprocess(submission)
        new.process(submission)
      end

      def import_from_webhook(page_id:, leadgen_id:)
        return if MetaLeadSubmission.exists?(leadgen_id: leadgen_id)

        result = Meta::AdsManagerService.new.lead_detail(page_id: page_id, leadgen_id: leadgen_id)
        unless result.success
          Rails.logger.error("Meta::LeadAds::ImportService: falha ao buscar lead #{leadgen_id}: #{result.error}")
          return
        end

        data = result.data
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
      end

      def process(submission)
        lead_form = MetaLeadForm.find_by(form_id: submission.form_id, active: true)

        # Notificar por WhatsApp é independente do mapeamento no CRM — dispara
        # mesmo pra formulário ainda sem pipeline configurado (ver
        # Meta::LeadAds::WhatsappNotifierService sobre a resolução do destino).
        Meta::LeadAds::WhatsappNotifierService.call(submission)

        unless lead_form
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

        pipeline_item = lead_form.pipeline.pipeline_items.find_by(contact: contact, completed_at: nil) ||
                        lead_form.pipeline.add_contact(contact, lead_form.pipeline_stage, nil)

        submission.update!(
          meta_lead_form: lead_form,
          contact: contact,
          pipeline_item: pipeline_item,
          status: 'processed',
          error_message: nil
        )
      rescue StandardError => e
        Rails.logger.error("Meta::LeadAds::ImportService: #{e.message}")
        submission.update(status: 'error', error_message: e.message)
      end

      private

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
        parsed = {}
        Array(field_data).each do |f|
          field_name = f['name'].to_s
          value = Array(f['values']).first
          next if value.blank?

          FIELD_NAME_PATTERNS.each do |key, pattern|
            parsed[key] ||= value if field_name.match?(pattern)
          end
        end
        parsed
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
