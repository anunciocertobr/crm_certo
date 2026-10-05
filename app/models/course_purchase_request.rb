# frozen_string_literal: true

# == Schema Information
#
# Table name: course_purchase_requests
#
#  id           :uuid             not null, primary key
#  course_id    :uuid             not null
#  currency     :string           default("BRL"), not null
#  decided_at   :datetime
#  decided_by_id: uuid
#  note         :text
#  payment_method: string         default("pix"), not null
#  price_cents  :integer          not null
#  status       :string           default("pending"), not null
#  user_id      :uuid             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Pedido de compra de curso pago. Nao ha gateway no CRM: o aluno paga por fora
# (PIX do criador) e quem decide e o proprio criador, que aprova e libera o
# acesso. Guardamos o preco QUE O ALUNO VIU no pedido, para o comprador e o
# vendedor divergirem sobre valor nao afetarem o historico.
#
class CoursePurchaseRequest < ApplicationRecord
  STATUSES = %w[pending approved rejected cancelled].freeze
  PAYMENT_METHODS = %w[pix boleto transferencia].freeze

  belongs_to :course

  validates :status, inclusion: { in: STATUSES }
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :pending, -> { where(status: 'pending') }
  scope :recent, -> { order(created_at: :desc) }

  def pending?
    status == 'pending'
  end

  def approved?
    status == 'approved'
  end

  # Aprovar libera o curso: a inscricao nasce junto, porque no CRM o pagamento
  # manual so tem um desfecho possivel — o aluno entrou.
  def approve!(approver)
    return false unless pending?

    transaction do
      update!(status: 'approved', decided_by_id: approver&.id, decided_at: Time.current)
      CourseEnrollment.find_or_create_by!(course_id: course_id, user_id: user_id) do |enrollment|
        enrollment.source = 'purchase'
        enrollment.started_at = Time.current
      end
      course.increment!(:students_count)
    end

    true
  end

  def reject!(approver, note: nil)
    return false unless pending?

    update!(status: 'rejected', decided_by_id: approver&.id, decided_at: Time.current, note: note)
    true
  end
end
