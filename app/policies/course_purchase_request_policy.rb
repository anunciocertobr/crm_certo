# frozen_string_literal: true

# CoursePurchaseRequestPolicy - quem decide um pedido e o curso, e quem cancela
# o proprio pedido.
class CoursePurchaseRequestPolicy < ApplicationPolicy
  def show?
    return false if user.blank?

    mine? || owned_by_user?
  end

  def approve?
    owned_by_user?
  end

  def reject?
    owned_by_user?
  end

  def cancel?
    mine?
  end

  private

  def mine?
    record.user_id == user&.id
  end

  def owned_by_user?
    record.course&.creator_profile&.user_id == user&.id
  end
end
