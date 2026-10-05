# frozen_string_literal: true

# Courses::VideoMetadata - titulo, thumbnail e duracao do video, via oEmbed.
#
# O editor mostra a capa e a duracao do video assim que a URL e colada, para o
# criador nao descobrir que colou o video errado so depois de publicar. Both
# YouTube and Vimeo respondem oEmbed sem chave de API.
#
# Nunca levanta excecao para o editor: video sem metadados continua valendo,
# so perde a capa automatica. O que falha aqui nao pode impedir cadastro.
module Courses::VideoMetadata
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 5

  module_function

  # => { title:, thumbnail_url:, duration_seconds: } — campos nil quando o
  # provider nao respondeu ou a URL nao e de video conhecido.
  def fetch(provider, video_id, embed_url: nil)
    url = embed_url.presence || Courses::VideoUrlParser.embed_url(provider, video_id)
    return empty_result if url.blank?

    case provider
    when 'youtube' then fetch_youtube(url)
    when 'vimeo' then fetch_vimeo(url)
    else empty_result
    end
  end

  def fetch_youtube(embed_url)
    body = get_json("https://www.youtube.com/oembed?url=#{CGI.escape(embed_url)}&format=json")
    return empty_result if body.nil?

    {
      title: body['title'],
      thumbnail_url: body['thumbnail_url'],
      duration_seconds: nil # oEmbed do YouTube nao devolve duracao
    }
  end

  def fetch_vimeo(embed_url)
    body = get_json("https://vimeo.com/api/oembed.json?url=#{CGI.escape(embed_url)}")
    return empty_result if body.nil?

    {
      title: body['title'],
      thumbnail_url: body['thumbnail_url'],
      duration_seconds: body['duration'].to_i.positive? ? body['duration'].to_i : nil
    }
  end

  def empty_result
    { title: nil, thumbnail_url: nil, duration_seconds: nil }
  end

  def get_json(url)
    uri = URI.parse(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                               open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.get(uri.request_uri, 'User-Agent' => 'EvoCRM-Courses/1.0')
    end

    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue StandardError => e
    Rails.logger.info("[courses] oEmbed indisponivel para #{url}: #{e.class}")
    nil
  end
end