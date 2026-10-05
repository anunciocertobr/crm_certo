# frozen_string_literal: true

# CoursePolicy - escrita e do dono do curso; leitura e publica.
#
# O catalogo e global: qualquer usuario autenticado ve curso publicado, de
# qualquer empresa. Rascunho so o dono ve.
class CoursePolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @scope = scope
    end

    # Sem regra por usuario: o catalogo e global. O que muda e o rascunho, e
    # quem pede o rascunho e o proprio dono.
    def resolve
      return scope.all if user.nil?

      scope.where(status: 'published')
          .or(scope.where(creator_profile_id: creator_profile_ids))
    end

    private

    def creator_profile_ids
      @creator_profile_ids ||= CreatorProfile.where(user_id: user.id).select(:id)
    end
  end

  def index?
    user.present?
  end

  def show?
    return false if user.blank?

    record.published? || owned_by_user?
  end

  def create?
    user.present?
  end

  def update?
    owned_by_user?
  end

  def destroy?
    owned_by_user?
  end

  def publish?
    owned_by_user?
  end

  private

  def owned_by_user?
    return false if user.blank?

    record.creator_profile&.user_id == user.id
  end
end
