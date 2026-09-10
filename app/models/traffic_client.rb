# Cadastro manual dos clientes de tráfego (agência) — não tem relação com
# Contact/CRM, é uma lista separada mantida pelo próprio usuário só pra
# organizar quem são os clientes de Marketing/Tráfego. Sem vínculo com contas
# de anúncio por enquanto (Painel Tráfego não filtra por isso ainda).
class TrafficClient < ApplicationRecord
  validates :name, presence: true

  scope :active_only, -> { where(active: true) }
end
