# frozen_string_literal: true

# Inscricoes do aluno: entrar em curso, pedir compra de curso pago e registrar
# onde parou em cada aula.
#
# Curso gratuito -> inscricao na hora. Curso pago -> pedido de compra, que so o
# criador aprova (CoursePurchaseRequest#approve! cria a inscricao).
class Api::V1::CourseEnrollmentsController < Api::V1::BaseController
  before_action :set_course, only: :create

  # As inscricoes do usuario logado, com progresso. É o "Meus cursos" e
  # alimenta a linha "Continuar assistindo".
  def index
    enrollments = CourseEnrollment.where(user_id: current_user.id)
                                   .includes(course: :creator_profile)
                                   .recent

    paginated_response(
      data: enrollments.map { |enrollment| serialize_enrollment(enrollment) },
      collection: enrollments,
      message: 'Enrollments retrieved successfully'
    )
  end

  def show
    enrollment = CourseEnrollment.find_by!(id: params[:id], user_id: current_user.id)

    success_response(data: serialize_enrollment(enrollment, detailed: true), message: 'Enrollment retrieved successfully')
  end

  # POST /api/v1/courses/:slug/enrollments
  #
  # Respond 201 com a inscricao quando o curso e gratuito; quando e pago,
  # responde 202 com o pedido criado. O codigo HTTP diferente e o que permite a
  # tela dizer "pedido enviado, aguarde o vendedor" sem adivinhar pelo corpo.
  def create
    authorize @course, :show?

    existing = CourseEnrollment.find_by(course_id: @course.id, user_id: current_user.id)
    return success_response(data: serialize_enrollment(existing), message: 'Already enrolled') if existing

    return enroll_free if @course.free?

    request_purchase
  end

  private

  def enroll_free
    enrollment = create_enrollment!(@course, 'free')
    @course.increment!(:students_count)

    success_response(
      data: serialize_enrollment(enrollment),
      message: 'Enrolled in free course',
      status: :created
    )
  end

  def request_purchase
    method = params[:payment_method].presence
    if method.present? && !CoursePurchaseRequest::PAYMENT_METHODS.include?(method)
      return error_response(ApiErrorCodes::INVALID_PARAMETER, 'Invalid payment_method',
                            details: { allowed: CoursePurchaseRequest::PAYMENT_METHODS }, status: :bad_request)
    end

    request_record = pending_purchase(@course, method || 'pix')

    success_response(
      data: CoursePurchaseRequestSerializer.serialize(request_record, viewer: current_user),
      message: 'Purchase request created; access unlocks when the seller approves it',
      status: :accepted
    )
  end

  def set_course
    @course = Course.published.find_by!(slug: params[:slug])
  end

  def create_enrollment!(course, source)
    CourseEnrollment.create!(course: course, user_id: current_user.id, source: source, started_at: Time.current)
  end

  # Reaproveita o pedido ainda pendente: dois cliques em "comprar" nao podem
  # criar duas linhas na fila do criador.
  def pending_purchase(course, payment_method)
    CoursePurchaseRequest.pending.find_by(course_id: course.id, user_id: current_user.id) ||
      CoursePurchaseRequest.create!(
        course: course,
        user_id: current_user.id,
        price_cents: course.price_cents,
        currency: course.currency,
        payment_method: payment_method,
        note: params[:note].presence
      )
  end

  def serialize_enrollment(enrollment, detailed: false)
    payload = {
      id: enrollment.id,
      status: enrollment.status,
      source: enrollment.source,
      progress_percent: enrollment.progress_percent,
      last_lesson_id: enrollment.last_lesson_id,
      started_at: enrollment.started_at&.iso8601,
      last_watched_at: enrollment.last_watched_at&.iso8601,
      completed_at: enrollment.completed_at&.iso8601,
      course: CourseSerializer.serialize(enrollment.course, viewer: current_user)
    }

    return payload unless detailed

    payload.merge(lessons: lesson_payloads(enrollment))
  end

  # Progresso por aula, indexado para nao consultar N vezes no mesmo curso.
  def lesson_payloads(enrollment)
    progresses = LessonProgress.where(course_enrollment_id: enrollment.id)
                               .includes(:course_lesson)
                               .index_by(&:course_lesson_id)

    enrollment.course.lessons_in_order.map do |lesson|
      progress = progresses[lesson.id]
      {
        id: lesson.id,
        title: lesson.title,
        position: lesson.position,
        duration_seconds: lesson.duration_seconds,
        is_preview: lesson.is_preview,
        completed: progress&.completed || false,
        position_seconds: progress&.position_seconds.to_i
      }
    end
  end
end