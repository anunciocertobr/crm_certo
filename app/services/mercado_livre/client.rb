# Cliente da API do Mercado Livre — autenticação OAuth2 por vendedor
# (refresh_token persistido em Integrations::Hook, app_id: 'mercado_livre'),
# diferente do client_credentials global do iFood (Ifood::Client): cada
# conta final do CRM conectou a PRÓPRIA loja ML, então o token é por hook,
# não por classe.
#
# #connected?/#search_orders testados contra a API real em 26/10/2026 (conta
# CA20250712202133, sem pedidos ainda — resposta real da API confirmada,
# paging.total: 0, não erro). #order_details/#publish_item/#update_item
# continuam SEM teste real (sem pedido/produto publicado ainda pra
# exercitar); #publish_item principalmente — payload de criação de anúncio
# tem bastante variação por categoria real do ML.
class MercadoLivre::Client
  BASE_URL = 'https://api.mercadolibre.com'
  TOKEN_URL = 'https://api.mercadolibre.com/oauth/token'

  class Error < StandardError; end
  class NotConnected < Error; end

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'mercado_livre')
  end

  def connected?
    @hook&.settings&.dig('access_token').present?
  end

  def user_id
    @hook&.settings&.dig('user_id')
  end

  # --- Pedidos ---

  # `order.status in (paid)` é o filtro mais comum pra sincronizar só
  # pedidos já pagos — quem chama decide o filtro real.
  def search_orders(status: nil, offset: 0, limit: 50)
    params = { seller: user_id, offset: offset, limit: limit }
    params[:'order.status'] = status if status.present?
    get('/orders/search', params: params)
  end

  def order_details(ml_order_id)
    get("/orders/#{ml_order_id}")
  end

  # --- Catálogo/publicação ---

  def item_details(ml_item_id)
    get("/items/#{ml_item_id}")
  end

  # Cria um anúncio novo. `category_id`/`attributes` variam MUITO por
  # categoria real do ML — este payload cobre só os campos universais
  # (title/price/currency_id/available_quantity/condition/listing_type_id/
  # pictures); categorias específicas (ex. eletrônicos exigem `brand`/
  # `model` como atributo tipado, não string livre) provavelmente vão
  # precisar de ajuste assim que testado contra uma categoria real.
  def publish_item(category_id:, title:, price:, quantity:, condition: 'new', listing_type_id: 'gold_special',
                    description: nil, picture_urls: [], buying_mode: 'buy_it_now', attributes: [])
    body = {
      title: title,
      category_id: category_id,
      price: price,
      currency_id: 'BRL',
      available_quantity: quantity,
      buying_mode: buying_mode,
      condition: condition,
      listing_type_id: listing_type_id,
      pictures: picture_urls.map { |url| { source: url } },
      attributes: attributes.presence
    }.compact
    item = post('/items', body)
    return item if description.blank? || item['id'].blank?

    post("/items/#{item['id']}/description", { plain_text: description })
    item
  end

  def update_item(ml_item_id, price: nil, quantity: nil, status: nil)
    body = { price: price, available_quantity: quantity, status: status }.compact
    put("/items/#{ml_item_id}", body)
  end

  def pause_item(ml_item_id)
    update_item(ml_item_id, status: 'paused')
  end

  private

  def access_token
    settings = @hook&.settings || {}
    expires_on = settings['expires_on'].present? ? Time.zone.parse(settings['expires_on']) : nil
    return settings['access_token'] if expires_on && expires_on > 1.minute.from_now

    refresh_access_token
  end

  def refresh_access_token
    raise NotConnected, 'Mercado Livre não conectado.' unless @hook&.settings&.dig('refresh_token')

    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'grant_type' => 'refresh_token',
                                      'client_id' => GlobalConfigService.load('MERCADO_LIVRE_CLIENT_ID', nil),
                                      'client_secret' => GlobalConfigService.load('MERCADO_LIVRE_CLIENT_SECRET', nil),
                                      'refresh_token' => @hook.settings['refresh_token']
                                    })
    raise Error, "Falha ao renovar token do Mercado Livre: #{response.code} #{response.body}" unless response.code.to_i.between?(200, 299)

    parsed = JSON.parse(response.body)
    @hook.settings = @hook.settings.merge(
      'access_token' => parsed['access_token'],
      'refresh_token' => parsed['refresh_token'] || @hook.settings['refresh_token'],
      'expires_on' => (Time.current.utc + parsed['expires_in'].to_i.seconds).to_s
    )
    @hook.save!
    parsed['access_token']
  end

  def get(path, params: {})
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params) if params.present?
    response = HTTParty.get(uri.to_s, headers: auth_headers)
    handle(response)
  end

  def post(path, body)
    response = HTTParty.post("#{BASE_URL}#{path}", body: body.to_json, headers: auth_headers.merge('Content-Type' => 'application/json'))
    handle(response)
  end

  def put(path, body)
    response = HTTParty.put("#{BASE_URL}#{path}", body: body.to_json, headers: auth_headers.merge('Content-Type' => 'application/json'))
    handle(response)
  end

  def auth_headers
    raise NotConnected, 'Mercado Livre não conectado.' unless connected?

    { 'Authorization' => "Bearer #{access_token}" }
  end

  def handle(response)
    return nil if response.code == 204
    raise Error, "Erro na API do Mercado Livre #{response.code}: #{response.body}" unless response.success?
    return nil if response.body.blank?

    JSON.parse(response.body)
  end
end
