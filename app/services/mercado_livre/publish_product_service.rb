# Publica (cria ou atualiza) um Product no Mercado Livre, usando os campos
# `ml_*` já existentes no model (ver migration 20260814140000) — `ml_category`
# é obrigatório (sem categoria real do ML o #publish_item da API recusa).
#
# Testado contra a API real em 28/10/2026 (categoria MLB11172/Consoles,
# conta CA20250712202133) — a tentativa SEM `attributes` foi rejeitada
# (BRAND/MODEL/VOLTAGE obrigatórios nessa categoria, erro 400
# "missing.attribute"); `build_attributes` abaixo foi adicionado por causa
# disso. Toda categoria do ML pede um conjunto diferente de atributos
# obrigatórios — descobrir via `GET /categories/:id/attributes` (campo
# `tags.required`) antes de publicar numa categoria nova; não tem como
# saber sem checar, a API só recusa.
class MercadoLivre::PublishProductService
  Result = Struct.new(:success, :error, keyword_init: true)

  def initialize(client: MercadoLivre::Client.new)
    @client = client
  end

  def call(product)
    return Result.new(success: false, error: 'Mercado Livre não conectado.') unless @client.connected?
    return Result.new(success: false, error: 'Produto sem ml_category definida.') if product.ml_category.blank?

    if product.ml_item_id.present?
      update_existing(product)
    else
      create_new(product)
    end
  rescue MercadoLivre::Client::Error => e
    product.update(ml_sync_error: e.message)
    Result.new(success: false, error: e.message)
  end

  private

  def create_new(product)
    item = @client.publish_item(
      category_id: product.ml_category,
      title: product.name,
      price: product.default_price,
      quantity: product.stock_quantity || 1,
      condition: product.ml_condition.presence || 'new',
      listing_type_id: product.ml_listing_type.presence || 'gold_special',
      description: product.description,
      picture_urls: product.media.to_a.filter_map { |m| m['url'] },
      attributes: build_attributes(product)
    )
    product.update!(ml_item_id: item['id'], ml_published_at: Time.current, ml_sync_error: nil)
    Result.new(success: true)
  end

  def update_existing(product)
    @client.update_item(product.ml_item_id, price: product.default_price, quantity: product.stock_quantity)
    product.update!(ml_published_at: Time.current, ml_sync_error: nil)
    Result.new(success: true)
  end

  # BRAND/MODEL vêm das colunas próprias do produto (brand/model) quando
  # preenchidas; `product.ml_attributes` (jsonb livre, ex.: {"VOLTAGE" =>
  # "Bivolt"}) completa ou sobrescreve — cada categoria da ML pede um
  # conjunto diferente, não dá pra fixar uma lista só.
  def build_attributes(product)
    attrs = {}
    attrs['BRAND'] = product.brand if product.brand.present?
    attrs['MODEL'] = product.model if product.model.present?
    attrs.merge!(product.ml_attributes) if product.ml_attributes.present?
    attrs.map { |id, value_name| { id: id, value_name: value_name.to_s } }
  end
end
