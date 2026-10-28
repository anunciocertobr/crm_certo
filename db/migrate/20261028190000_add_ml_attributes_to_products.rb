# Atributos tipados exigidos pela Mercado Livre por categoria (ex.: BRAND,
# MODEL, VOLTAGE) — category_id MLB11172 (Consoles) já exige os 3 pra
# aceitar o POST /items, confirmado ao vivo em 28/10/2026 testando a
# publicação real (ver MercadoLivre::PublishProductService). BRAND/MODEL já
# tinham coluna própria (brand/model, reaproveitados como default); o resto
# (VOLTAGE e qualquer atributo específico de categoria) entra aqui, livre,
# porque cada categoria da ML pede um conjunto diferente.
class AddMlAttributesToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :ml_attributes, :jsonb, default: {}, null: false, if_not_exists: true
  end
end
