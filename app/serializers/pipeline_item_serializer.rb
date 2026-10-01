# frozen_string_literal: true

# PipelineItemSerializer - Optimized serialization for PipelineItem resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   PipelineItemSerializer.serialize(@pipeline_item, include_entity: true)
#
module PipelineItemSerializer
  extend self

  # Serialize single PipelineItem
  #
  # @param pipeline_item [PipelineItem] PipelineItem to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_entity Include entity details (conversation or contact)
  #
  # @return [Hash] Serialized pipeline item ready for Oj
  #
  # Build a per-item task-count index in bulk, so callers serializing many items
  # don't fire 5 COUNT queries per item (N+1). Mirrors the labels_by_* batching
  # below. Pass the result as `task_counts_by_item:` to #serialize.
  #
  # @param items [Array<PipelineItem>, ActiveRecord::Relation]
  # @return [Hash{String => Hash}] item_id => {pending:, overdue:, due_soon:, completed:, total:}
  def task_counts_for(items)
    ids = items.map(&:id)
    return {} if ids.empty?

    # status is an integer-backed enum, but Rails (7.1) returns the string label
    # as the group key here (verified against prod: keys are ["<uuid>", "pending"]).
    # Key the lookups by label string accordingly.
    by_status = PipelineTask.where(pipeline_item_id: ids).group(:pipeline_item_id, :status).count
    totals    = PipelineTask.where(pipeline_item_id: ids).group(:pipeline_item_id).count
    due_soon  = PipelineTask.where(pipeline_item_id: ids)
                            .where('due_date > ? AND due_date <= ?', Time.current, 1.hour.from_now)
                            .group(:pipeline_item_id).count

    ids.index_with do |id|
      {
        pending: by_status.fetch([id, 'pending'], 0),
        overdue: by_status.fetch([id, 'overdue'], 0),
        due_soon: due_soon.fetch(id, 0),
        completed: by_status.fetch([id, 'completed'], 0),
        total: totals.fetch(id, 0)
      }
    end
  end

  # Batch pra serializar coleções sem 1 query de WhatsappAdLead por item —
  # mesma ideia de task_counts_for acima. O mais recente por contato vence
  # (um contato pode ter clicado em mais de um anúncio ao longo do tempo;
  # o card de lead reflete a atribuição mais recente).
  def ad_attribution_for(items)
    contact_ids = items.filter_map { |i| i.contact&.id }.uniq
    return {} if contact_ids.empty?

    WhatsappAdLead.where(contact_id: contact_ids).order(created_at: :desc).group_by(&:contact_id).transform_values(&:first)
  end

  def serialize(pipeline_item, include_entity: false, include_tasks_info: false,
                include_services_info: false, include_labels: false,
                labels_by_title: nil, labels_by_id: nil, task_counts_by_item: nil,
                ad_attribution_by_contact: nil)
    is_task = pipeline_item.task_item?

    is_orphaned = if is_task
                    false
                  elsif pipeline_item.conversation_id.present?
                    !pipeline_item.conversation.present?
                  elsif pipeline_item.contact_id.present?
                    !pipeline_item.contact.present?
                  else
                    true
                  end

    result = {
      id: pipeline_item.id,
      pipeline_id: pipeline_item.pipeline_id,
      pipeline_stage_id: pipeline_item.pipeline_stage_id,
      stage_id: pipeline_item.pipeline_stage_id,
      conversation_id: pipeline_item.conversation_id,
      contact_id: pipeline_item.contact_id,
      item_id: pipeline_item.conversation_id || pipeline_item.contact_id,
      type: is_task ? 'task' : (pipeline_item.lead? ? 'contact' : 'conversation'),
      is_lead: pipeline_item.lead?,
      custom_fields: pipeline_item.custom_fields || {},
      entered_at: pipeline_item.entered_at&.to_i,
      completed_at: pipeline_item.completed_at&.to_i,
      days_in_pipeline: pipeline_item.days_in_pipeline,
      days_in_current_stage: pipeline_item.days_in_current_stage,
      created_at: pipeline_item.created_at&.to_i,
      updated_at: pipeline_item.updated_at&.iso8601,
      is_orphaned: is_orphaned,
      lead_quality: pipeline_item.lead_quality,
      lead_score: pipeline_item.lead_score,
      lead_objection: pipeline_item.lead_objection,
      lead_observation: pipeline_item.lead_observation,
      lead_qualified_at: pipeline_item.lead_qualified_at&.to_i
    }

    contact_for_attribution = pipeline_item.contact
    if contact_for_attribution.present?
      lead = ad_attribution_by_contact ? ad_attribution_by_contact[contact_for_attribution.id] : WhatsappAdLead.where(contact_id: contact_for_attribution.id).order(created_at: :desc).first
      result[:ad_attribution] = serialize_ad_attribution(lead) if lead.present?
    end

    if is_task
      primary_task = pipeline_item.primary_task
      result[:title] = primary_task&.title
      result[:description] = primary_task&.description
      result[:priority] = primary_task&.priority
      result[:due_date] = primary_task&.due_date&.iso8601
      result[:task_status] = primary_task&.status
      result[:primary_task_id] = primary_task&.id
      if primary_task&.assigned_to
        result[:assignee] = {
          id: primary_task.assigned_to.id,
          name: primary_task.assigned_to.name,
          email: primary_task.assigned_to.email,
          avatar_url: primary_task.assigned_to.avatar_url
        }
      end
    end

    return result if is_orphaned
    if include_entity && pipeline_item.conversation.present? && pipeline_item.association(:conversation).loaded? && pipeline_item.conversation
      result[:conversation] = ConversationSerializer.serialize(
        pipeline_item.conversation,
        include_messages: false,
        include_labels: include_labels,
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      )
      result[:conversation]['uuid'] = pipeline_item.conversation.uuid
      if pipeline_item.conversation.association(:contact).loaded? && pipeline_item.conversation.contact
        # include_labels: false — the pipelines board does not render contact labels
        # (it uses conversation.labels), and contact.labels triggers an N+1 (tags load
        # + a Label.find_by per tag). Skipping it keeps GET /pipelines off the timeout.
        result[:contact] = ContactSerializer.serialize(pipeline_item.conversation.contact, include_labels: false)
      end
      if pipeline_item.conversation.association(:assignee).loaded? && pipeline_item.conversation.assignee
        result[:assignee] = {
          id: pipeline_item.conversation.assignee.id,
          name: pipeline_item.conversation.assignee.name,
          email: pipeline_item.conversation.assignee.email,
          avatar_url: pipeline_item.conversation.assignee.avatar_url,
          available_name: pipeline_item.conversation.assignee.available_name
        }
      end
    end

    if include_entity && pipeline_item.contact.present? && pipeline_item.association(:contact).loaded? && pipeline_item.contact
      # include_labels: false — see note above; pipelines board does not use contact labels.
      result[:contact] = ContactSerializer.serialize(pipeline_item.contact, include_labels: false)
    end

    # Include tasks info if requested. When a pre-computed batch index is passed
    # (collection serialization), read from it to avoid 5 COUNT queries per item.
    # Falls back to the per-item methods for single-item callers (e.g. #show).
    if include_tasks_info
      counts = task_counts_by_item && task_counts_by_item[pipeline_item.id]
      result[:tasks_info] = if counts
                              {
                                pending_count: counts[:pending],
                                overdue_count: counts[:overdue],
                                due_soon_count: counts[:due_soon],
                                completed_count: counts[:completed],
                                total_count: counts[:total]
                              }
                            else
                              {
                                pending_count: pipeline_item.pending_tasks_count,
                                overdue_count: pipeline_item.overdue_tasks_count,
                                due_soon_count: pipeline_item.due_soon_tasks_count,
                                completed_count: pipeline_item.completed_tasks_count,
                                total_count: pipeline_item.tasks.count
                              }
                            end
    end

    # Include services info if requested
    if include_services_info
      currency = pipeline_item.custom_fields&.dig('currency') || 'BRL'
      total_value = pipeline_item.services_total_value
      services = pipeline_item.custom_fields&.dig('services') || []
      
      result[:services_info] = {
        total_value: total_value,
        currency: currency,
        formatted_total: pipeline_item.formatted_services_total(currency),
        services_count: services.length,
        has_services: services.any? && total_value > 0,
        services: services.map do |service|
          service_info = {
            name: service['name'],
            value: service['value'].to_f
          }
          service_info[:service_definition_id] = service['service_definition_id'] if service['service_definition_id'].present?
          service_info
        end
      }
      result[:value] = total_value
    end

    result
  end

  # Clique de anúncio (ver Whatsapp::AdReferralCapture) + UTMs — alimenta o
  # painel "Dados do Lead" e o ícone de origem no card do Kanban.
  def serialize_ad_attribution(lead)
    {
      platform: lead.platform,
      source_id: lead.source_id,
      source_type: lead.source_type,
      source_url: lead.source_url,
      ctwaclid: lead.ctwaclid,
      gclid: lead.gclid,
      headline: lead.headline,
      body: lead.body,
      thumbnail_url: lead.thumbnail_url,
      campaign_id: lead.campaign_id,
      campaign_name: lead.campaign_name,
      adset_id: lead.adset_id,
      adset_name: lead.adset_name,
      ad_id: lead.ad_id,
      ad_name: lead.ad_name,
      utm_source: lead.utm_source,
      utm_medium: lead.utm_medium,
      utm_campaign: lead.utm_campaign,
      utm_content: lead.utm_content,
      utm_term: lead.utm_term
    }
  end

  # Serialize collection of PipelineItems
  #
  # @param pipeline_items [Array<PipelineItem>, ActiveRecord::Relation]
  #
  # @return [Array<Hash>] Array of serialized pipeline items
  #
  def serialize_collection(pipeline_items, **options)
    return [] unless pipeline_items

    items = pipeline_items.to_a
    options[:ad_attribution_by_contact] ||= ad_attribution_for(items)
    items.map { |item| serialize(item, **options) }
  end
end
