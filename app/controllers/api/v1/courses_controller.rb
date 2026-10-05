# frozen_string_literal: true

# Vitrine de cursos (marketplace global). Qualquer usuario autenticado navega;
# rascunho so o dono (CoursePolicy#show?).
class Api::V1::CoursesController < Api::V1::BaseController
  ROW_LIMIT = 20

  before_action :set_course, only: :show

  # Lista com filtros.
  def index
    scope = paginated_scope

    paginated_response(
      data: CourseSerializer.serialize_collection(scope, viewer: current_user),
      collection: scope,
      message: 'Courses retrieved successfully'
    )
  end

  def show
    authorize @course

    success_response(
      data: CourseDetailSerializer.serialize(@course, viewer: current_user),
      message: 'Course retrieved successfully'
    )
  end

  # As linhas da home do aluno (o "Netflix"). Endpoint separado do index para
  # que a listagem com filtros continue sendo uma pagina simples.
  def rows
    success_response(data: carrousel_rows, message: 'Course rows retrieved successfully')
  end

  private

  def set_course
    @course = Course.find_by!(slug: params[:slug])
  end

  def paginated_scope
    scope = Course.published
                  .includes(:creator_profile)
                  .by_category(params[:category])
                  .search(params[:search])

    scope = scope.free if params[:free].to_s == 'true'
    scope = scope.paid if params[:paid].to_s == 'true'

    creator = find_creator
    return scope.where(creator_profile_id: creator.id) if creator

    scope.recently_published
  end

  def find_creator
    return nil if params[:creator].blank?

    CreatorProfile.find_by(slug: params[:creator]) || CreatorProfile.find_by(id: params[:creator])
  end

  # Cada linha ja vem pronta para o carrossel. As tres primeiras dependem do
  # aluno (o que ele parou, esta inscribed, terminou); as de descoberta sao do
  # catalogo inteiro.
  def carrousel_rows
    viewer = current_user
    enrollments = CourseEnrollment.where(user_id: viewer.id).includes(course: :creator_profile).reorder(nil)

    {
      # Continuar assistindo: tem aula comecada e nao terminou.
      continue_watching: cards(enrollments.in_progress.limit(ROW_LIMIT).map(&:course), viewer),
      enrolled: cards(enrollments.active.where(last_watched_at: nil).limit(ROW_LIMIT).map(&:course), viewer),
      completed: cards(enrollments.completed.limit(ROW_LIMIT).map(&:course), viewer),
      wishlist: cards(wishlisted_courses(viewer), viewer),
      following: cards(followed_courses(viewer), viewer),
      trending: cards(Course.published.order(students_count: :desc, published_at: :desc).limit(ROW_LIMIT), viewer),
      free: cards(Course.published.free.recently_published.limit(ROW_LIMIT), viewer),
      new: cards(Course.published.recently_published.limit(ROW_LIMIT), viewer)
    }
  end

  # `carrousel_rows` ja traz metade das linhas como Array (vindo de
  # `enrollments...map(&:course)`) e metade como Relation. `.includes` so existe
  # na Relation, entao normalizar aqui evita NoMethodError em metade da home.
  def cards(scope, viewer)
    courses = scope.is_a?(ActiveRecord::Relation) ? scope.includes(:creator_profile) : scope
    CourseSerializer.serialize_collection(courses, viewer: viewer)
  end

  def wishlisted_courses(viewer)
    Course.where(id: CourseWishlist.where(user_id: viewer.id).select(:course_id))
          .published.recently_published.limit(ROW_LIMIT)
  end

  def followed_courses(viewer)
    followed = CreatorFollow.where(user_id: viewer.id).select(:creator_profile_id)
    Course.where(creator_profile_id: followed).published.recently_published.limit(ROW_LIMIT)
  end
end