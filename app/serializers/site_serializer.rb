# frozen_string_literal: true

# SiteSerializer — serialização de Site pro card de Dashboards > Sites.
# Nunca expõe `webhook_token` aqui — só sai via Api::V1::SitesController#webhook_info,
# uma tela separada e deliberada.
module SiteSerializer
  extend self

  def serialize(site, leads_count: nil)
    {
      id: site.id,
      url: site.url,
      name: site.name,
      hostname: site.hostname,
      active: site.active,
      leads_count: leads_count || 0,
      created_at: site.created_at&.iso8601,
      updated_at: site.updated_at&.iso8601
    }
  end
end
