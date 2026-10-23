# Publica (cria ou atualiza) um Product no Mercado Livre, usando os campos
# `ml_*` já existentes no model (ver migration 20260814140000) — `ml_category`
# é obrigatório (sem categoria real do ML o #publish_item da API recusa).
#
# NUNCA TESTADO CONTRA A API REAL — ver nota em MercadoLivre::Client.
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
      picture_urls: product.media.to_a.filter_map { |m| m['url'] }
    )
    product.update!(ml_item_id: item['id'], ml_published_at: Time.current, ml_sync_error: nil)
    Result.new(success: true)
  end

  def update_existing(product)
    @client.update_item(product.ml_item_id, price: product.default_price, quantity: product.stock_quantity)
    product.update!(ml_published_at: Time.current, ml_sync_error: nil)
    Result.new(success: true)
  end
end
