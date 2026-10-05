# frozen_string_literal: true

# Perfil de venda do usuario logado. Criado sob demanda: quem abre a area do
# criador pela primeira vez ja ganha um perfil com o nome do cadastro.
class Api::V1::Creator::ProfilesController < Api::V1::BaseController
  include CurrentCreator

  def show
    authorize current_creator

    success_response(
      data: CreatorProfileSerializer.serialize(current_creator, viewer: current_user, mine: true),
      message: 'Creator profile retrieved successfully'
    )
  end

  def update
    authorize current_creator

    if current_creator.update(profile_params)
      success_response(
        data: CreatorProfileSerializer.serialize(current_creator, viewer: current_user, mine: true),
        message: 'Creator profile updated successfully'
      )
    else
      validation_error(current_creator)
    end
  end

  # POST .../publish — o perfil precisa estar publicado para os cursos dele
  # aparecerem na vitrine publicavel.
  def publish
    authorize current_creator, :publish?

    if current_creator.courses.published.none?
      return error_response(ApiErrorCodes::VALIDATION_ERROR, 'Publique ao menos um curso antes de publicar o perfil',
                            status: :unprocessable_entity)
    end

    current_creator.update!(is_published: true, published_at: current_creator.published_at || Time.current)

    success_response(
      data: CreatorProfileSerializer.serialize(current_creator, viewer: current_user, mine: true),
      message: 'Creator profile published'
    )
  end

  def unpublish
    authorize current_creator, :publish?

    current_creator.update!(is_published: false)

    success_response(
      data: CreatorProfileSerializer.serialize(current_creator, viewer: current_user, mine: true),
      message: 'Creator profile unpublished'
    )
  end

  private

  def profile_params
    params.require(:creator_profile).permit(
      :display_name, :headline, :bio, :avatar_url, :banner_url, :whatsapp, :pix_key
    )
  end
end
