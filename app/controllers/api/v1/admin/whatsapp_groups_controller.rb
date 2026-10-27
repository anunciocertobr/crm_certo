# Lista os grupos de WhatsApp de uma inbox Evolution/Evolution Go — alimenta
# o seletor de grupo na notificação de leads (ver
# Meta::LeadAds::WhatsappNotifierService, NotifyChannelsEditor.tsx).
class Api::V1::Admin::WhatsappGroupsController < Api::V1::Admin::BaseController
  # GET /whatsapp_groups?inbox_id=...
  def index
    inbox = Inbox.find_by(id: params[:inbox_id])
    return render json: { success: true, data: [] } unless inbox

    channel = inbox.channel
    unless channel.respond_to?(:provider) && channel.provider.in?(%w[evolution evolution_go])
      return render json: { success: true, data: [], reason: 'unsupported_provider' }
    end

    groups = channel.provider_service.fetch_all_groups
    render json: { success: true, data: groups }
  end
end
