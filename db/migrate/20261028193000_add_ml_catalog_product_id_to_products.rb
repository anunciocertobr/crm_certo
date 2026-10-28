# Categorias populares/padronizadas da ML (ex.: MLB11172/Consoles) exigem
# "publicação em catálogo" — POST /items com catalog_product_id +
# catalog_listing:true em vez de title/attributes livres (a ficha técnica
# vem do produto de catálogo da própria ML). Confirmado ao vivo em
# 28/10/2026: publicar um Console PS4 com title/attributes livres foi
# recusado (400 "fields [title] are invalid for requested call") até
# trocar pra esse modo. Achar o catalog_product_id certo: GET /products/
# search?domain_id=...&q=... (autenticado) — ver
# MercadoLivre::PublishProductService.
class AddMlCatalogProductIdToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :ml_catalog_product_id, :string, limit: 50, if_not_exists: true
  end
end
