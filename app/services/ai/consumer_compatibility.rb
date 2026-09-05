# frozen_string_literal: true

# Which providers each AI feature can actually talk to (FR18).
#
# AI Agents reach every provider through the core service. The others build a
# `POST /chat/completions` call, so a non-OpenAI provider there is not a
# misconfiguration but a different protocol, and it fails at the wire.
#
# New consumers register here; the resolver needs no change.
class Ai::ConsumerCompatibility
  ALL_PROVIDERS = :all

  CONSUMERS = {
    ai_agents: ALL_PROVIDERS,
    inbox_assist: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    audio_transcription: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    label_suggestion: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    moderation: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    # ToolsProxyController#openai_chat_completions — the Marketing AI tools'
    # "ChatGPT" option. Groq/Gemini go through their own Integrations::Hook
    # (see require_key!); only OpenAI has no hook-based key input anymore
    # (apps.yml moved it to this registry), so this is the only way to reach it.
    marketing_ai_tools: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS
  }.freeze

  class << self
    def known?(consumer)
      CONSUMERS.key?(consumer&.to_sym)
    end

    def accepted_providers(consumer)
      CONSUMERS[consumer&.to_sym]
    end

    def accepts?(consumer, provider)
      accepted = accepted_providers(consumer)
      return false if accepted.nil?
      return true if accepted == ALL_PROVIDERS

      accepted.include?(provider)
    end
  end
end
