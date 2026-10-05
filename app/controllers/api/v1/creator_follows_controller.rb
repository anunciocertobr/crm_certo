# frozen_string_literal: true

# Seguir um vendedor de curso: alimenta a linha "quem voce segue" na area do
# aluno. Sem isso, seguir era so um numero que ninguem usava.
class Api::V1::CreatorFollowsController < Api::V1::BaseController
  before_action :set_creator

  def index
    creators = CreatorProfile.published
                             .where(id: CreatorFollow.where(user_id: current_user.id).select(:creator_profile_id))
                             .order_by_name

    paginated_response(
      data: CreatorProfileSerializer.serialize_collection(creators, viewer: current_user),
      collection: creators,
      message: 'Following retrieved successfully'
    )
  end

  def create
    follow = CreatorFollow.find_or_create_by!(creator_profile_id: @creator.id, user_id: current_user.id)
    was_new = follow.previously_new_record?
    @creator.increment!(:followers_count) if was_new

    success_response(
      data: { id: follow.id, creator_profile_id: @creator.id, following: true },
      message: 'Following creator',
      status: was_new ? :created : :ok
    )
  end

  def destroy
    destroyed = CreatorFollow.where(creator_profile_id: @creator.id, user_id: current_user.id).destroy_all.count
    @creator.decrement!(:followers_count) if destroyed.positive?

    success_response(data: { creator_profile_id: @creator.id, following: false }, message: 'Unfollowed creator')
  end

  private

  def set_creator
    @creator = CreatorProfile.published.find_by!(slug: params[:creator_slug] || params[:slug])
  end
end
