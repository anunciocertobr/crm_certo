# frozen_string_literal: true

# ContactSerializer - Optimized serialization for Contact resources
#
# This is a plain Ruby module (NOT ActiveModel::Serializer) designed to work
# directly with Oj for maximum performance. No intermediate layers.
#
# Usage:
#   ContactSerializer.serialize(@contact, include_contact_inboxes: true)
#   ContactSerializer.serialize_collection(@contacts, include_labels: true)
#
module ContactSerializer
  extend self

  # Serialize single Contact with optimized field selection
  #
  # @param contact [Contact] Contact to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_contact_inboxes Include contact_inboxes association
  # @option options [Boolean] :include_labels Include labels (default: true)
  # @option options [Boolean] :include_companies Include companies for person type
  # @option options [Boolean] :include_pipelines Include pipeline data
  #
  # @return [Hash] Serialized contact ready for Oj
  #
  def serialize(contact, include_contact_inboxes: false, include_labels: true, include_companies: false, include_pipelines: false, include_ad_lead: false, labels_by_title: nil, ad_lead_by_contact_id: nil)
    result = contact.as_json(
      only: [:id, :name, :type, :email, :phone_number, :identifier, :blocked,
             :availability_status, :tax_id, :website, :industry],
    )

    # EVO-1551: mask PII server-side when the account flag is on AND the current
    # user is not an admin. Defence-in-depth alongside the frontend hook — without
    # this, the Network tab still leaks the raw values even though the UI hides
    # them.
    if ContactPiiMasker.should_mask?
      result['email'] = ContactPiiMasker.mask_email(result['email'])
      result['phone_number'] = ContactPiiMasker.mask_phone(result['phone_number'])
      result['identifier'] = ContactPiiMasker.mask_identifier(result['identifier'])
      result['name'] = ContactPiiMasker.mask_phone_like_name(result['name'])
    end

    # Add computed fields
    result['additional_attributes'] = contact.additional_attributes || {}
    result['custom_attributes'] = contact.custom_attributes || {}
    result['thumbnail'] = contact.avatar_url.presence

    # Timestamps as integers (faster than ISO8601 strings)
    result['created_at'] = contact.created_at.to_i
    result['last_activity_at'] = contact.last_activity_at&.to_i

    # Conditionally include labels
    if include_labels
      result['labels'] = serialize_labels(contact, labels_by_title)
    end

    # Conditionally include contact_inboxes
    if include_contact_inboxes
      mask_source_id = ContactPiiMasker.should_mask?
      result['contact_inboxes'] = contact.contact_inboxes.select { |ci| ci.inbox.present? }.map do |ci|
        {
          # source_id carries the channel-specific identifier (phone JID for
          # WhatsApp, email for IMAP, etc.). Mask via the identifier helper so
          # both phone- and email-shaped values are hidden uniformly.
          source_id: mask_source_id ? ContactPiiMasker.mask_identifier(ci.source_id) : ci.source_id,
          inbox: {
            id: ci.inbox.id,
            name: ci.inbox.name,
            channel_type: ci.inbox.channel_type
          }
        }
      end
    end

    # Conditionally include companies/persons
    if include_companies
      mask_related = ContactPiiMasker.should_mask?
      if contact.type == 'person'
        result['companies'] = contact.companies.map do |company|
          {
            id: company.id,
            name: company.name,
            type: company.type,
            email: mask_related ? ContactPiiMasker.mask_email(company.email) : company.email,
            phone_number: mask_related ? ContactPiiMasker.mask_phone(company.phone_number) : company.phone_number,
            thumbnail: company.avatar_url.presence
          }
        end
      elsif contact.type == 'company'
        result['persons'] = contact.comp_contacts.map do |person|
          {
            id: person.id,
            name: person.name,
            type: person.type,
            email: mask_related ? ContactPiiMasker.mask_email(person.email) : person.email,
            phone_number: mask_related ? ContactPiiMasker.mask_phone(person.phone_number) : person.phone_number,
            thumbnail: person.avatar_url.presence
          }
        end
        result['persons_count'] = contact.company_contacts.size
      end
    end

    # Conditionally include pipelines
    if include_pipelines
      result['pipelines'] = serialize_pipelines(contact)
    end

    # Dados de pixel (Meta) ligados a este contato/suas conversas — ver
    # Whatsapp::AdReferralCapture, tabela ad_leads (campanha/conjunto/
    # anúncio/UTMs/ctwaclid/fbc/fbp/valor_venda). Pedido do usuário: tela
    # de Contatos mostrar isso igual à aba Site de Dashboards, só que
    # puxando do CRM (ad_leads), não do webhook de site.
    if include_ad_lead
      result['ad_lead'] = ad_lead_by_contact_id ? ad_lead_by_contact_id[contact.id] : serialize_ad_lead(contact)
    end

    result
  end

  # Serialize collection of Contacts
  # Uses Oj's optimized array handling
  #
  # @param contacts [Array<Contact>, ActiveRecord::Relation] Contacts to serialize
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized contacts
  #
  def serialize_collection(contacts, **options)
    return [] unless contacts

    labels_by_title = options.fetch(:include_labels, true) ? labels_by_title_for(contacts) : nil
    ad_lead_by_contact_id = options.fetch(:include_ad_lead, false) ? ad_lead_by_contact_id_for(contacts) : nil

    contacts.map { |contact| serialize(contact, labels_by_title: labels_by_title, ad_lead_by_contact_id: ad_lead_by_contact_id, **options) }
  end

  private

  # Um contato pode ter mais de um AdLead (cliques em anúncios diferentes
  # ao longo do tempo) — pega o mais recente, mesmo critério de "dado
  # atual" usado no resto do produto (ex. última campanha que gerou
  # contato). Batch por contact_id evita N+1 na lista.
  def ad_lead_by_contact_id_for(contacts)
    ids = contacts.map(&:id)
    return {} if ids.empty?

    AdLead.where(contact_id: ids).order(created_at: :desc).group_by(&:contact_id).transform_values do |leads|
      serialize_ad_lead_record(leads.first)
    end
  end

  def serialize_ad_lead(contact)
    lead = AdLead.where(contact_id: contact.id).order(created_at: :desc).first
    serialize_ad_lead_record(lead)
  end

  def serialize_ad_lead_record(lead)
    return nil unless lead

    {
      campaign_name: lead.campaign_name,
      adset_name: lead.adset_name,
      ad_name: lead.ad_name,
      utm_source: lead.utm_source,
      utm_medium: lead.utm_medium,
      utm_campaign: lead.utm_campaign,
      ctwaclid: lead.ctwaclid,
      valor_venda: lead.valor_venda
    }
  end

  def labels_by_title_for(contacts)
    titles = contacts.flat_map { |contact| contact.labels.map(&:name) }.uniq
    return {} if titles.empty?

    Label.where(title: titles).index_by(&:title)
  end

  def serialize_labels(contact, labels_by_title)
    contact.labels.map do |tag|
      label = labels_by_title ? labels_by_title[tag.name] : Label.find_by(title: tag.name)
      { name: tag.name, color: label&.color || '#1f93ff' }
    end
  end

  # Serialize pipeline data for a contact
  def serialize_pipelines(contact)
    return [] unless contact

    conversation_ids = contact.conversations.pluck(:id)

    pipeline_items = PipelineItem
                       .includes(:pipeline, :pipeline_stage, pipeline_item_products: [:product, :product_variant])
                       .where('contact_id = ? OR conversation_id IN (?)', contact.id, conversation_ids)

    pipeline_items.group_by(&:pipeline).map do |pipeline, items|
      item = items.first
      stage = item.pipeline_stage

      {
        pipeline: {
          id: pipeline.id,
          name: pipeline.name,
          pipeline_type: pipeline.pipeline_type
        },
        stage: {
          id: stage.id,
          name: stage.name,
          color: stage.color,
          position: stage.position,
          stage_type: stage.stage_type
        },
        item: {
          id: item.id,
          item_id: item.contact_id || item.conversation_id,
          type: item.lead? ? 'lead' : 'deal',
          entered_at: item.entered_at&.to_i || item.created_at.to_i,
          notes: item.custom_fields&.dig('notes'),
          # "Pedido" nativo do CRM — pedido do usuário: produto/valor/
          # order_id na tela de Contatos, igual à aba Site de Dashboards.
          # order_id = este mesmo pipeline_item.id (não existe um model
          # "Order" separado neste CRM — PipelineItem É o pedido/card do
          # Kanban); products = PipelineItemProduct (quantidade × preço
          # travado no momento da venda, não o preço atual do produto).
          products: item.pipeline_item_products.map do |pip|
            {
              name: pip.product_variant&.name.presence || pip.product&.name,
              quantity: pip.quantity,
              unit_price: pip.locked_unit_price,
              total: (pip.quantity * pip.locked_unit_price).round(2),
              currency: pip.currency
            }
          end,
          products_total: item.pipeline_item_products.sum { |pip| pip.quantity * pip.locked_unit_price }.round(2)
        }
      }
    end
  end
end
