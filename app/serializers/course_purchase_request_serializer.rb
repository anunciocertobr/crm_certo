# frozen_string_literal: true

# CoursePurchaseRequestSerializer - pedido de compra, visto pelo aluno
# (status) ou pelo criador (fila de aprovacao, com nome e contato do comprador).
module CoursePurchaseRequestSerializer
  extend self

  STATUS_LABELS = {
    'pending' => 'Aguardando pagamento',
    'approved' => 'Aprovado',
    'rejected' => 'Recusado',
    'cancelled' => 'Cancelado'
  }.freeze

  def serialize(request, viewer: nil)
    buyer = viewer && User.find_by(id: request.user_id)

    {
      id: request.id,
      status: request.status,
      status_label: STATUS_LABELS.fetch(request.status, request.status),
      payment_method: request.payment_method,
      price_cents: request.price_cents,
      price_formatted: format_price(request),
      currency: request.currency,
      note: request.note,
      course: course_summary(request),
      student: student_summary(request, buyer),
      decided_at: request.decided_at&.iso8601,
      created_at: request.created_at&.iso8601,
      updated_at: request.updated_at&.iso8601
    }
  end

  def serialize_collection(requests, viewer: nil)
    return [] unless requests

    requests.map { |request| serialize(request, viewer: viewer) }
  end

  private

  def course_summary(request)
    course = request.course
    return nil if course.nil?

    { id: course.id, slug: course.slug, title: course.title, thumbnail_url: course.thumbnail_url }
  end

  # O criador precisa de saber quem esta comprando (para chamar no WhatsApp e
  # conferir o PIX). O aluno ve apenas os proprios dados.
  def student_summary(request, buyer)
    return nil if buyer.nil?

    {
      id: buyer.id,
      name: buyer.name,
      email: buyer.email
    }
  end

  def format_price(request)
    return 'Gratuito' if request.price_cents.zero?

    ActionController::Base.helpers.number_to_currency(request.price_cents / 100.0, unit: 'R$ ')
  end
end
