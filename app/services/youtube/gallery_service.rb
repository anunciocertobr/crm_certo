# Leitura do canal/vídeos do YouTube conectado (mesma conexão Google usada
# pra upload em Youtube::UploadService) pra tela "Gestor de Posts" — usa a
# YouTube Data API v3: channels.list(mine=true) pra dados do canal + o
# playlistId de uploads, depois playlistItems.list nesse playlist pra listar
# os vídeos, e videos.list pra trazer as estatísticas (visualizações etc.)
# de cada um.
require 'net/http'
require 'uri'
require 'json'

class Youtube::GalleryService
  BASE_URL = 'https://www.googleapis.com/youtube/v3'.freeze

  class Error < StandardError; end

  def account_info
    data = get('channels', part: 'snippet,statistics,contentDetails', mine: 'true')
    channel = data['items']&.first
    raise Error, 'Nenhum canal do YouTube encontrado para esta conta.' if channel.nil?

    channel
  end

  def videos(limit: 25)
    channel = account_info
    playlist_id = channel.dig('contentDetails', 'relatedPlaylists', 'uploads')
    return [] if playlist_id.blank?

    items = get('playlistItems', part: 'snippet,contentDetails', playlistId: playlist_id, maxResults: limit)['items'] || []
    video_ids = items.filter_map { |i| i.dig('contentDetails', 'videoId') }
    stats_by_id = video_ids.any? ? fetch_statistics(video_ids) : {}

    items.map do |item|
      video_id = item.dig('contentDetails', 'videoId')
      item.merge('statistics' => stats_by_id[video_id])
    end
  end

  private

  def fetch_statistics(video_ids)
    videos = get('videos', part: 'statistics', id: video_ids.join(','))['items'] || []
    videos.each_with_object({}) { |v, acc| acc[v['id']] = v['statistics'] }
  end

  def access_token
    Google::WorkspaceTokenService.new.access_token
  end

  def get(path, **params)
    token = access_token
    raise Error, 'Conexão com o Google não encontrada. Conecte em Configurações > Integrações.' if token.blank?

    uri = URI("#{BASE_URL}/#{path}")
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    response = http.request(request)
    body = JSON.parse(response.body)

    raise Error, "#{body.dig('error', 'code')} - #{body.dig('error', 'message')}" if body['error'].present?

    body
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da YouTube Data API: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao consultar a YouTube Data API.'
  end
end
