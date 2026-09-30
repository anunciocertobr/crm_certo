# Cliente salvo pra reaproveitar na emissão de NFS-e (nome, CPF/CNPJ, e-mail
# e endereço) — pedido do usuário pra não redigitar os dados toda vez que
# emite nota pra um tomador recorrente. `endereco` guarda o mesmo formato de
# `ServiceInvoice#tomador_endereco`, então o front copia o objeto direto ao
# preencher o formulário de emissão a partir de um tomador salvo.
class FiscalTomador < ApplicationRecord
  # Sem isso o Rails infere a tabela como "fiscal_tomadors" (só acrescenta
  # "s" — não conhece plural em português), mas a migração criou
  # "fiscal_tomadores" (plural certo).
  self.table_name = 'fiscal_tomadores'

  validates :nome, :cpf_cnpj, presence: true
  validates :cpf_cnpj, uniqueness: true

  scope :alphabetical, -> { order(:nome) }
end
