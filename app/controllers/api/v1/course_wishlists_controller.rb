# frozen_string_literal: true

# Lista de desejo. POST e DELETE sao idempotentes: clicar duas vezes no
# coracao, ou apertar F5, nao pode estourar unique index nem devolver 409.
class Api::V1::CourseWishlistsController < Api::V1::BaseController
  before_action :set_course

  def index
    wishlisted = Course.where(id: CourseWishlist.where(user_id: current_user.id).select(:course_id))
                       .published.recently_published

    paginated_response(
      data: CourseSerializer.serialize_collection(wishlisted, viewer: current_user),
      collection: wishlisted,
      message: 'Wishlist retrieved successfully'
    )
  end

  def create
    wishlist = CourseWishlist.find_or_create_by!(course_id: @course.id, user_id: current_user.id)

    success_response(
      data: { id: wishlist.id, course_id: @course.id, wishlisted: true },
      message: 'Added to wishlist',
      status: :created
    )
  end

  def destroy
    CourseWishlist.where(course_id: @course.id, user_id: current_user.id).destroy_all

    success_response(data: { course_id: @course.id, wishlisted: false }, message: 'Removed from wishlist')
  end

  private

  def set_course
    @course = Course.published.find_by!(slug: params[:course_slug] || params[:slug])
  end
end
