# Cliente da Shopee Open Platform API v2 — autenticação OAuth2 por loja
# (refresh_token persistido em Integrations::Hook, app_id: 'shopee').
# Diferente de ML/iFood: TODA chamada (não só o login) exige assinatura
# HMAC-SHA256 própria no corpo/query (partner_id + path + timestamp +
# access_token + shop_id, com o partner_key) — não basta um Bearer token.
#
# NUNCA TESTADO CONTRA A API REAL — sem app Shopee cadastrado ainda (ver
# ShopeeAuthorizationsController). Nomes de campo/endpoint seguem a
# documentação pública da Shopee Open Platform v2; confirmar contra a API
# real assim que houver credencial, principalmente #publish_item (o
# payload de criação de produto exige category_id/attributes/logistics da
# Shopee, que têm validação própria por categoria e país).
class Shopee::Client
  BASE_URL = 'https://partner.shopeemobile.com'
  TOKEN_PATH = '/api/v2/auth/access_token/get'

  class Error < StandardError; end
  class NotConnected < Error; end

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'shopee')
  end

  def connected?
    @hook&.settings&.dig('access_token').present?
  end

  def shop_id
    @hook&.settings&.dig('shop_id')&.to_i
  end

  # --- Pedidos ---

  def order_list(time_from:, time_to:, status: nil, cursor: '')
    params = {
      time_range_field: 'create_time',
      time_from: time_from.to_i,
      time_to: time_to.to_i,
      page_size: 50,
      cursor: cursor
    }
    params[:order_status] = status if status.present?
    get('/api/v2/order/get_order_list', params: params)
  end

  def order_detail(order_sn_list)
    get('/api/v2/order/get_order_detail', params: { order_sn_list: Array(order_sn_list).join(',') })
  end

  # --- Catálogo/publicação ---

  def item_base_info(item_id_list)
    get('/api/v2/product/get_item_base_info', params: { item_id_list: Array(item_id_list).join(',') })
  end

  # Payload mínimo universal — categorias reais da Shopee quase sempre
  # exigem `attribute_list`/`logistic_info` específicos (peso, dimensões,
  # garantia etc.) além destes campos base; vai precisar de ajuste por
  # categoria assim que testado contra a API real.
  def publish_item(category_id:, item_name:, description:, price:, stock:, image_ids: [])
    post('/api/v2/product/add_item', {
           category_id: category_id,
           item_name: item_name,
           description: description,
           price_info: [{ currency: 'BRL', original_price: price }],
           stock_info: [{ stock_type: 1, stock: stock }],
           image: { image_id_list: image_ids }
         })
  end

  def update_item(item_id, price: nil, stock: nil)
    update_price(item_id, price) if price.present?
    update_stock(item_id, stock) if stock.present?
  end

  def update_price(item_id, price)
    post('/api/v2/product/update_price', { item_id: item_id, price_list: [{ model_id: 0, original_price: price }] })
  end

  def update_stock(item_id, stock)
    post('/api/v2/product/update_stock', { item_id: item_id, stock_list: [{ model_id: 0, seller_stock: [{ stock: stock }] }] })
  end

  def unlist_item(item_id)
    post('/api/v2/product/unlist_item', { item_list: [{ item_id: item_id, unlist: true }] })
  end

  # Sobe UMA imagem pro media space da Shopee e devolve o image_id a usar
  # em `publish_item`/`image_ids`. Só ESSE endpoint da Shopee espera
  # multipart/form-data — todo resto da API é JSON — por isso não reusa o
  # `#post` genérico abaixo (Content-Type/body diferentes), mas reusa a
  # mesma assinatura HMAC via `signed_query`.
  #
  # io: qualquer objeto que responda a #read (ex.: um ActiveStorage::Blob
  # aberto com `.open { |file| ... }`, ou um File/StringIO comum).
  def upload_image(io, filename:)
    path = '/api/v2/media_space/upload_image'
    query = signed_query(path, access_token: access_token, shop_id: shop_id)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(query)
    response = HTTParty.post(
      uri.to_s,
      body: { image: UploadIO.new(io, mime_type_for(filename), filename) },
      multipart: true
    )
    parsed = handle(response)
    image_id = parsed&.dig('response', 'image_info', 'image_id')
    raise Error, "Upload de imagem na Shopee não devolveu image_id: #{parsed.inspect}" if image_id.blank?

    image_id
  end

  private

  def mime_type_for(filename)
    case File.extname(filename).downcase
    when '.png' then 'image/png'
    when '.gif' then 'image/gif'
    when '.webp' then 'image/webp'
    else 'image/jpeg'
    end
  end

  def partner_id
    GlobalConfigService.load('SHOPEE_PARTNER_ID', nil)
  end

  def partner_key
    GlobalConfigService.load('SHOPEE_PARTNER_KEY', nil)
  end

  def access_token
    settings = @hook&.settings || {}
    expires_on = settings['expires_on'].present? ? Time.zone.parse(settings['expires_on']) : nil
    return settings['access_token'] if expires_on && expires_on > 1.minute.from_now

    refresh_access_token
  end

  def refresh_access_token
    raise NotConnected, 'Shopee não conectado.' unless @hook&.settings&.dig('refresh_token')

    query = signed_query(TOKEN_PATH, shop_id: shop_id)
    uri = URI("#{BASE_URL}#{TOKEN_PATH}")
    uri.query = URI.encode_www_form(query)
    response = Net::HTTP.post(uri, {
      refresh_token: @hook.settings['refresh_token'],
      shop_id: shop_id,
      partner_id: partner_id.to_i
    }.to_json, 'Content-Type' => 'application/json')
    raise Error, "Falha ao renovar token da Shopee: #{response.code} #{response.body}" unless response.code.to_i.between?(200, 299)

    parsed = JSON.parse(response.body)
    raise Error, "Falha ao renovar token da Shopee: #{parsed['message']}" if parsed['error'].present?

    @hook.settings = @hook.settings.merge(
      'access_token' => parsed['access_token'],
      'refresh_token' => parsed['refresh_token'] || @hook.settings['refresh_token'],
      'expires_on' => (Time.current.utc + parsed['expire_in'].to_i.seconds).to_s
    )
    @hook.save!
    parsed['access_token']
  end

  def signed_query(path, access_token: nil, shop_id: nil)
    raise NotConnected, 'Shopee não conectado.' if access_token.nil? && shop_id.nil? && path != TOKEN_PATH

    timestamp = Time.current.to_i
    base_string = "#{partner_id}#{path}#{timestamp}#{access_token}#{shop_id}"
    sign = OpenSSL::HMAC.hexdigest('SHA256', partner_key, base_string)
    { partner_id: partner_id, timestamp: timestamp, sign: sign, access_token: access_token, shop_id: shop_id }.compact
  end

  def get(path, params: {})
    query = signed_query(path, access_token: access_token, shop_id: shop_id).merge(params)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(query)
    response = HTTParty.get(uri.to_s)
    handle(response)
  end

  def post(path, body)
    query = signed_query(path, access_token: access_token, shop_id: shop_id)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(query)
    response = HTTParty.post(uri.to_s, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
    handle(response)
  end

  def handle(response)
    return nil if response.code == 204
    raise Error, "Erro na API da Shopee #{response.code}: #{response.body}" unless response.success?
    return nil if response.body.blank?

    parsed = JSON.parse(response.body)
    raise Error, "Erro na API da Shopee: #{parsed['message']}" if parsed['error'].present?

    parsed
  end
end
