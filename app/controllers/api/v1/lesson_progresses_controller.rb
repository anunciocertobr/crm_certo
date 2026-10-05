# frozen_string_literal: true

# Progresso de aula: "onde parei" e "ja terminei".
#
# O player chama a cada ~15s e no pause. Por isso o endpoint e idempotente por
# (inscricao, aula) e aceita updates parciais: nao vale rejeitar o heartbeat
# porque o aluno chegou aos 90% sem tocar em "concluir".
class Api::V1::LessonProgressesController < Api::V1::BaseController
  # PUT /api/v1/course_enrollments/:enrollment_id/lesson_progresses
  def upsert
    lesson = lesson_from_request

    unless @enrollment.course.course_lessons.exists?(lesson.id)
      return error_response(ApiErrorCodes::INVALID_PARAMETER, 'Lesson does not belong to this course',
                            details: { lesson_id: lesson.id }, status: :unprocessable_entity)
    end

    progress = save_progress(lesson)
    update_enrollment(lesson)

    success_response(
      data: {
        lesson_id: lesson.id,
        position_seconds: progress.position_seconds,
        completed: progress.completed,
        course_progress_percent: @enrollment.reload.progress_percent,
        enrollment_status: @enrollment.status
      },
      message: 'Progress saved'
    )
  end

  private

  def set_enrollment
    @enrollment = CourseEnrollment.find_by!(id: params[:enrollment_id], user_id: current_user.id)
  end

  def lesson_from_request
    set_enrollment
    CourseLesson.find(params[:lesson_id])
  end

  def save_progress(lesson)
    progress = LessonProgress.find_or_initialize_by(
      course_enrollment_id: @enrollment.id,
      course_lesson_id: lesson.id
    )

    progress.position_seconds = clamp_position(params[:position_seconds], lesson)
    progress.completed = params[:completed].to_s == 'true'
    progress.last_watched_at = Time.current
    progress.completed_at = progress.completed ? (progress.completed_at || Time.current) : nil
    progress.save!

    progress
  end

  def update_enrollment(lesson)
    @enrollment.update!(last_lesson_id: lesson.id, last_watched_at: Time.current)
    @enrollment.recalculate_progress!(total_lessons: @enrollment.course.course_lessons.count)
  end

  # `position_seconds` vem do player. Acima da duracao da aula significa que o
  # player mandou lixo: melhor gravar o inicio da aula do que um progresso de
  # 40 horas que quebraria a barra de progresso.
  def clamp_position(value, lesson)
    seconds = value.to_i
    seconds = 0 if seconds.negative?
    return seconds if lesson.duration_seconds.to_i.zero?

    [seconds, lesson.duration_seconds.to_i].min
  end
end