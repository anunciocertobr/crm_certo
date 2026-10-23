# Publica (cria ou atualiza) um Product na Shopee, usando os campos
# `shopee_*` novos no model (migration 20261015210200) — `shopee_category_id`
# é obrigatório (sem categoria real da Shopee o #publish_item da API recusa).
#
# NUNCA TESTADO CONTRA A API REAL — ver nota em Shopee::Client. Sobe as
# imagens do próprio Product (ActiveStorage, `has_many_attached :images`)
# pro media space da Shopee ANTES de criar o produto, já que a API exige
# image_id (não URL direta) — ver Shopee::Client#upload_image. Um produto
# sem nenhuma imagem anexada publica mesmo assim (a Shopee aceita item sem
# imagem, só não recomendado); erro de upload numa imagem individual não
# derruba as outras, só fica de fora da lista.
class Shopee::PublishProductService
  Result = Struct.new(:success, :error, keyword_init: true)

  # Shopee aceita no máximo 9 imagens por item (doc pública da Open
  # Platform v2) — cortar aqui evita a API recusar o publish_item inteiro
  # por causa de imagens demais.
  MAX_IMAGES = 9

  def initialize(client: Shopee::Client.new)
    @client = client
  end

  def call(product)
    return Result.new(success: false, error: 'Shopee não conectada.') unless @client.connected?
    return Result.new(success: false, error: 'Produto sem shopee_category_id definida.') if product.shopee_category_id.blank?

    if product.shopee_item_id.present?
      update_existing(product)
    else
      create_new(product, upload_images(product))
    end
  rescue Shopee::Client::Error => e
    product.update(shopee_sync_error: e.message)
    Result.new(success: false, error: e.message)
  end

  private

  # Melhor-esforço: uma imagem que falhar no upload é pulada (logada), não
  # trava a publicação do produto inteiro por causa de um arquivo ruim.
  def upload_images(product)
    return [] unless product.respond_to?(:images) && product.images.attached?

    product.images.first(MAX_IMAGES).filter_map do |attachment|
      attachment.blob.open do |file|
        @client.upload_image(file, filename: attachment.filename.to_s)
      end
    rescue Shopee::Client::Error => e
      Rails.logger.warn("Shopee: falha ao subir imagem #{attachment.id} do produto #{product.id}: #{e.message}")
      nil
    end
  end

  def create_new(product, image_ids)
    response = @client.publish_item(
      category_id: product.shopee_category_id.to_i,
      item_name: product.name,
      description: product.description.presence || product.name,
      price: product.default_price,
      stock: product.stock_quantity || 1,
      image_ids: image_ids
    )
    item_id = response.dig('response', 'item_id')
    product.update!(shopee_item_id: item_id, shopee_published_at: Time.current, shopee_sync_error: nil)
    Result.new(success: true)
  end

  def update_existing(product)
    @client.update_item(product.shopee_item_id, price: product.default_price, stock: product.stock_quantity)
    product.update!(shopee_published_at: Time.current, shopee_sync_error: nil)
    Result.new(success: true)
  end
end
