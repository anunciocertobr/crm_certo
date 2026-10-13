# Cache local de nome/foto de produtos do catálogo iFood, indexado pelo
# productId. Existe porque GET /catalog/v2.0/merchants/{id}/products (sem
# filtro de categoria) retorna 400 "Pagination parameters must be numeric"
# de forma consistente no sandbox — bug confirmado da API, não do payload
# (mesmo requestId repetido entre chamadas distintas). Como complementos
# (options) são produtos sem categoria/item, não aparecem em
# GET .../categories/{id}/items (que funciona normalmente), então não tem
# outra fonte confiável pra nome/foto depois da criação — preenchido no
# momento do #create_option (Api::V1::IfoodController).
class IfoodProductCache < ApplicationRecord
  self.table_name = 'ifood_product_cache'

  validates :ifood_product_id, presence: true, uniqueness: true
end
