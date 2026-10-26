# frozen_string_literal: true

module IntegrationHookSerializer
  extend self

  def serialize(hook, **options)
    return nil unless hook

    {
      id: hook.id,
      app_id: hook.app_id,
      inbox_id: hook.inbox_id,
      reference_id: hook.reference_id,
      status: hook.status,
      settings: hook.settings || {},
      hook_type: hook.hook_type,
      created_at: hook.created_at&.iso8601,
      updated_at: hook.updated_at&.iso8601
    }
  end

  def serialize_collection(hooks, **options)
    return [] unless hooks

    hooks.map { |hook| serialize(hook, **options) }
  end
end
