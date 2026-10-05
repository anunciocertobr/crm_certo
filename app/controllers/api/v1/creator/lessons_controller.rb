# frozen_string_literal: true

# Aulas do curso, na area do criador.
#
# A URL do video e colada e convertido em provider/id pelo model. O preview
# (POST /preview) nao grava nada: devolve o que o parser reconheceu e os
# metadados do video, para o criador conferir antes de salvar a aula.
class Api::V1::Creator::LessonsController < Api::V1::BaseController
  include CurrentCreator

  before_action :set_course
  before_action :set_lesson, only: %i[update destroy]

  # POST /api/v1/creator/courses/:course_slug/lessons/preview
  def preview
    parsed = Courses::VideoUrlParser.parse(params[:video_url])

    if parsed[:provider].blank?
      return error_response(
        ApiErrorCodes::INVALID_PARAMETER,
        'URL nao reconhecida como video do YouTube ou Vimeo',
        details: { video_url: params[:video_url] },
        status: :unprocessable_entity
      )
    end

    metadata = Courses::VideoMetadata.fetch(parsed[:provider], parsed[:video_id], embed_url: parsed[:embed_url])

    success_response(
      data: parsed.merge(metadata),
      message: 'Video recognized successfully'
    )
  end

  def create
    lesson = @course.course_lessons.new(lesson_params)
    lesson.course_module_id ||= @course.course_modules.first&.id
    authorize @course, :update?

    if lesson.course_module_id.blank?
      return error_response(ApiErrorCodes::VALIDATION_ERROR, 'Crie um modulo antes de adicionar aulas',
                            status: :unprocessable_entity)
    end

    lesson.course_id = @course.id

    if lesson.save
      sync_duration_from_metadata(lesson)
      @course.recalculate_stats!
      success_response(data: serialize_lesson(lesson), message: 'Lesson created successfully', status: :created)
    else
      validation_error(lesson)
    end
  end

  def update
    authorize @course, :update?

    if @lesson.update(lesson_params)
      sync_duration_from_metadata(@lesson)
      @course.recalculate_stats!
      success_response(data: serialize_lesson(@lesson), message: 'Lesson updated successfully')
    else
      validation_error(@lesson)
    end
  end

  def destroy
    authorize @course, :update?
    @lesson.destroy!
    @course.recalculate_stats!

    success_response(data: { id: @lesson.id }, message: 'Lesson deleted successfully')
  end

  private

  def set_course
    @course = current_creator.courses.find_by!(slug: params[:course_slug])
  end

  def set_lesson
    @lesson = @course.course_lessons.find(params[:id])
  end

  def lesson_params
    permitted = params.require(:course_lesson).permit(:course_module_id, :title, :description, :position, :video_url, :is_preview)
    permitted[:course_module_id] = @course.course_modules.find_by(id: permitted[:course_module_id])&.id if permitted[:course_module_id]
    permitted
  end

  # So sobrescreve a duracao quando o criador nao digitou: o oEmbed do YouTube
  # nem sempre devolve duracao, e quem sabe o numero e o proprio player.
  def sync_duration_from_metadata(lesson)
    return if lesson.duration_seconds.to_i.positive?

    metadata = Courses::VideoMetadata.fetch(lesson.video_provider, lesson.video_id, embed_url: lesson.embed_url)
    return if metadata[:duration_seconds].blank?

    lesson.update_column(:duration_seconds, metadata[:duration_seconds])
  end

  def serialize_lesson(lesson)
    {
      id: lesson.id,
      title: lesson.title,
      description: lesson.description,
      position: lesson.position,
      course_module_id: lesson.course_module_id,
      video_url: lesson.video_url,
      video_provider: lesson.video_provider,
      video_id: lesson.video_id,
      embed_url: lesson.embed_url,
      duration_seconds: lesson.reload.duration_seconds,
      is_preview: lesson.is_preview
    }
  end
end
