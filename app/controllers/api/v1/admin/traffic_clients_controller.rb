# Lista de clientes de tráfego (agência) usada em Marketing — cadastro manual
# e solto, sem relação com Contact/CRM nem com contas de anúncio (ver
# TrafficClient).
class Api::V1::Admin::TrafficClientsController < Api::V1::Admin::BaseController
  def index
    clients = TrafficClient.active_only.order(:name)
    render json: { success: true, data: clients.map { |c| serialize(c) } }
  end

  def create
    client = TrafficClient.new(client_params)
    if client.save
      render json: { success: true, data: serialize(client) }, status: :created
    else
      render json: { success: false, message: client.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def update
    client = TrafficClient.find(params[:id])
    if client.update(client_params)
      render json: { success: true, data: serialize(client) }
    else
      render json: { success: false, message: client.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: 'Cliente não encontrado' }, status: :not_found
  end

  # Soft-delete: mantém o histórico caso volte a ser referenciado no futuro.
  def destroy
    client = TrafficClient.find(params[:id])
    client.update!(active: false)
    render json: { success: true, data: serialize(client) }
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: 'Cliente não encontrado' }, status: :not_found
  end

  private

  def client_params
    params.permit(:name, :contact_name, :phone, :email, :notes)
  end

  def serialize(client)
    {
      id: client.id,
      name: client.name,
      contact_name: client.contact_name,
      phone: client.phone,
      email: client.email,
      notes: client.notes
    }
  end
end
