# frozen_string_literal: true

# Pagina publica do vendedor de curso: quem ele e e o que ele ja publicou.
# Rascunho nunca entra aqui (CreatorProfilePolicy#show? + Course.published), mas
# o perfil em si precisa existir para o aluno chegar no curso pela vitrine.
class Api::V1::CreatorsController < Api::V1::BaseController
  before_action :set_creator, only: :show

  def index
    creators = CreatorProfile.published
                             .where(id: Course.published.select(:creator_profile_id))
                             .order_by_name

    paginated_response(
      data: CreatorProfileSerializer.serialize_collection(creators, viewer: current_user),
      collection: creators,
      message: 'Creators retrieved successfully'
    )
  end

  def show
    authorize @creator

    success_response(
      data: profile_payload(@creator),
      message: 'Creator retrieved successfully'
    )
  end

  private

  def set_creator
    @creator = CreatorProfile.published.find_by!(slug: params[:id])
  end

  def profile_payload(creator)
    courses = Course.published.where(creator_profile_id: creator.id)
                     .includes(:creator_profile)
                     .recently_published

    {
      creator: CreatorProfileSerializer.serialize(creator, viewer: current_user),
      courses: CourseSerializer.serialize_collection(courses, viewer: current_user)
    }
  end
end