# Leitura de posts/página do Facebook pra tela "Gestor de Posts" — mesmo
# papel do Instagram::GalleryService, mas pra a própria página (feed do
# Facebook), não pro Instagram vinculado a ela. Serviço dedicado (em vez de
# reaproveitar Facebook::FetchPagePostsService, usado pela caixa de entrada
# com um conjunto de campos menor) pra não arriscar mudar o que já funciona
# lá.
require 'net/http'
require 'uri'
require 'json'

class Facebook::GalleryService
  POST_FIELDS = 'id,message,created_time,permalink_url,full_picture,' \
                'attachments{media_type,media,url},likes.summary(true),comments.summary(true)'.freeze
  ACCOUNT_FIELDS = 'name,fan_count,picture{url},link,about'.freeze
  # A Graph API de Stories da Página não devolve URL de mídia direto — só
  # post_id/media_id. Pra exibir uma prévia de verdade, buscamos o objeto de
  # mídia (foto ou vídeo) separadamente por media_id.
  STORY_FIELDS = 'post_id,status,creation_time,media_type,media_id,url'.freeze

  class Error < StandardError; end

  attr_reader :channel

  def initialize(channel:)
    @channel = channel
  end

  def account_info
    get(channel.page_id.to_s, fields: ACCOUNT_FIELDS)
  end

  def media(limit: 25)
    result = get("#{channel.page_id}/posts", fields: POST_FIELDS, limit: limit)
    result['data'] || []
  end

  # Stories ativos (24h) da página — GET /{page-id}/stories, igual ao Story
  # ativo do Instagram, mas exige pages_read_engagement/pages_manage_posts no
  # token; se a página não tiver a permissão ou nenhuma Story ativa, a Graph
  # API retorna lista vazia ou erro (propagado como Error).
  def stories
    result = get("#{channel.page_id}/stories", fields: STORY_FIELDS)
    items = result['data'] || []
    items.map { |story| story.merge('media_url' => fetch_story_media_url(story)) }
  end

  # DELETE /{post-id} com o token da página — endpoint padrão da Graph API
  # pra apagar um post publicado nela, exige a permissão pages_manage_posts.
  def delete_media(post_id)
    uri = URI("#{base_url}/#{post_id}")
    uri.query = URI.encode_www_form(access_token: access_token)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    response = http.request(Net::HTTP::Delete.new(uri.request_uri))
    body = JSON.parse(response.body)

    raise Error, "#{body.dig('error', 'code')} - #{body.dig('error', 'message')}" if body['error'].present?

    body
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da Graph API: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao excluir o post.'
  end

  private

  # Uma Story sem mídia acessível ainda aparece na lista (com media_url nil,
  # o front cai pro placeholder) — falha isolada por item nunca derruba a
  # lista inteira de Stories.
  def fetch_story_media_url(story)
    return nil if story['media_id'].blank?

    if story['media_type'].to_s.casecmp('video').zero?
      get(story['media_id'].to_s, fields: 'source')['source']
    else
      get(story['media_id'].to_s, fields: 'images').dig('images', 0, 'source')
    end
  rescue Error
    nil
  end

  def access_token
    channel.page_access_token
  end

  def base_url
    MetaBaseUrl.for(:facebook)
  end

  def get(path, **params)
    raise Error, 'Página do Facebook sem ID configurado.' if channel.page_id.blank?
    raise Error, 'Página do Facebook sem token de acesso configurado.' if access_token.blank?

    uri = URI("#{base_url}/#{path}")
    uri.query = URI.encode_www_form(params.merge(access_token: access_token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    response = http.request(Net::HTTP::Get.new(uri.request_uri))
    body = JSON.parse(response.body)

    raise Error, "#{body.dig('error', 'code')} - #{body.dig('error', 'message')}" if body['error'].present?

    body
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da Graph API: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao consultar a Graph API do Facebook.'
  end
end
