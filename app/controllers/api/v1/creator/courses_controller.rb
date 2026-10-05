# frozen_string_literal: true

# Cursos do usuario logado, na area do criador. Drafts Included: o rascunho nao
# existe para o publico, mas e onde o trabalho acontece.
class Api::V1::Creator::CoursesController < Api::V1::BaseController
  include CurrentCreator

  before_action :set_course, only: %i[show update destroy publish unpublish]

  def index
    courses = current_creator.courses.includes(:course_modules).order(updated_at: :desc)

    paginated_response(
      data: CourseSerializer.serialize_collection(courses, viewer: current_user),
      collection: courses,
      message: 'Your courses retrieved successfully'
    )
  end

  def show
    authorize @course

    success_response(data: CourseDetailSerializer.serialize(@course, viewer: current_user), message: 'Course retrieved successfully')
  end

  def create
    course = current_creator.courses.new(course_params)
    authorize course

    if course.save
      success_response(data: CourseSerializer.serialize(course, viewer: current_user), message: 'Course created successfully', status: :created)
    else
      validation_error(course)
    end
  end

  def update
    authorize @course

    if @course.update(course_params)
      success_response(data: CourseSerializer.serialize(@course, viewer: current_user), message: 'Course updated successfully')
    else
      validation_error(@course)
    end
  end

  def destroy
    authorize @course
    @course.destroy!

    success_response(data: { id: @course.id }, message: 'Course deleted successfully')
  end

  # Publicar / voltar para rascunho. Publicar exige aula com video: curso
  # publicado sem conteudo e pior que curso nao publicado, porque aparece na
  # vitrine do aluno.
  def publish
    authorize @course, :publish?

    if @course.lessons_count.zero?
      return error_response(ApiErrorCodes::VALIDATION_ERROR, 'Adicione ao menos uma aula com video antes de publicar',
                            details: { course_id: @course.id }, status: :unprocessable_entity)
    end

    @course.publish!

    success_response(data: CourseSerializer.serialize(@course, viewer: current_user), message: 'Course published')
  end

  def unpublish
    authorize @course, :publish?
    @course.unpublish!

    success_response(data: CourseSerializer.serialize(@course, viewer: current_user), message: 'Course unpublished')
  end

  private

  def set_course
    @course = current_creator.courses.find_by!(slug: params[:slug])
  end

  # `status` NAO e permittido de proposito: publicar passa por `publish!`,
  # que exige ao menos uma aula com video. Permitir aqui deixaria o criador
  # publicar curso vazio direto no update, contornando essa regra.
  def course_params
    params.require(:course).permit(
      :title, :subtitle, :description, :category, :level, :thumbnail_url,
      :trailer_url, :price_cents, :currency
    )
  end
end
