# frozen_string_literal: true

# CreatorProfilePolicy - cada um edita o proprio perfil de venda.
#
# `pix_key` entra no perfil publico de propósito: sem gateway de pagamento, e
# ela que o aluno copia para pagar, e esconder ia obrigar o criador a mandar
# chave por WhatsApp.
class CreatorProfilePolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @scope = scope
    end

    def resolve
      return scope.published if user.nil?

      scope.published.or(scope.where(user_id: user.id))
    end
  end

  def show?
    return false if user.blank?

    record.is_published? || mine?
  end

  def update?
    mine?
  end

  def publish?
    mine?
  end

  private

  def mine?
    user.present? && record.user_id == user.id
  end
end
