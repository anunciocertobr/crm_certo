# frozen_string_literal: true

# Fila de compras do criador. Sem gateway de pagamento: o aluno paga por fora e
# o criador aprova aqui, o que libera o acesso na hora.
class Api::V1::Creator::PurchaseRequestsController < Api::V1::BaseController
  include CurrentCreator

  before_action :set_request, only: %i[approve reject]

  def index
    requests = CoursePurchaseRequest.where(course_id: current_creator.courses.select(:id))
                                     .recent

    requests = requests.pending if params[:status].to_s == 'pending'

    paginated_response(
      data: CoursePurchaseRequestSerializer.serialize_collection(requests, viewer: current_user),
      collection: requests,
      message: 'Purchase requests retrieved successfully'
    )
  end

  def approve
    authorize @request, :approve?

    if @request.approve!(current_user)
      success_response(data: CoursePurchaseRequestSerializer.serialize(@request, viewer: current_user), message: 'Purchase approved')
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, 'Only pending requests can be approved', status: :unprocessable_entity)
    end
  end

  def reject
    authorize @request, :reject?

    if @request.reject!(current_user, note: params[:note])
      success_response(data: CoursePurchaseRequestSerializer.serialize(@request, viewer: current_user), message: 'Purchase rejected')
    else
      error_response(ApiErrorCodes::VALIDATION_ERROR, 'Only pending requests can be rejected', status: :unprocessable_entity)
    end
  end

  private

  def set_request
    @request = CoursePurchaseRequest.where(course_id: current_creator.courses.select(:id)).find(params[:id])
  end
end
