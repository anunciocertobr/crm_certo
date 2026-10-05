# frozen_string_literal: true

# CurrentCreator - o perfil de venda do usuário logado, criado sob demanda.
#
# A área do criador exige perfil: quem não tem, o primeiro save cria. Fazer isso
# no controller evita repetir o find_or_create_by em todo endpoint e garante
# que um usuario nunca publique curso sem perfil (a policy de escrita do curso
# aponta para o profile).
module CurrentCreator
  extend ActiveSupport::Concern

  included do
    before_action :ensure_creator_profile, only: %i[show update]
  end

  private

  def current_creator
    @current_creator ||= CreatorProfile.find_or_create_by!(user_id: current_user.id) do |profile|
      profile.display_name = current_user.name.presence || current_user.email.to_s.split('@').first
    end
  end

  def ensure_creator_profile
    current_creator
  end

  # Curso que o usuário logado pode escrever: precisa existir E ser dele. Curso
  # de outra pessoa devolve 403 via policy, não 404 — esconder a existência
  # alheia aqui só quebraria o editor sem ganhar nada.
  def owned_course!(course)
    authorize(course, :update?)
    course
  end
end