# frozen_string_literal: true

# Courses::VideoUrlParser - transforma a URL colada no editor em video tocavel.
#
# A aula nao guarda arquivo: guarda video do YouTube ou do Vimeo. Quem cria o
# curso cola a URL do endereco do navegador (que tem query string, barra final
# e as formas mais variadas que o mundo inventou de compartilhar video), e este
# servico extrai o par provider/id que o player precisa.
#
# Sem chave de API e sem rede: a embed do YouTube e a do Vimeo funcionam por
# id publico. Metadados (titulo/thumbnail) vem por oEmbed, em VideoMetadata.
module Courses::VideoUrlParser
  # IDs do YouTube sao 11 caracteres de [A-Za-z0-9_-]; Vimeo e numerico.
  YOUTUBE_ID = /[A-Za-z0-9_-]{11}/
  YOUTUBE_ID_EXACT = /\A[A-Za-z0-9_-]{11}\z/
  VIMEO_ID = /[0-9]+/

  # Formatos aceitos, em ordem. Cada entrada: host + caminho que carrega o id.
  YOUTUBE_HOSTS = %w[
    youtube.com
    www.youtube.com
    m.youtube.com
    music.youtube.com
    youtu.be
    www.youtu.be
  ].freeze

  VIMEO_HOSTS = %w[
    vimeo.com
    www.vimeo.com
    player.vimeo.com
  ].freeze

  YOUTUBE_PATH_FORMS = [
    %r{\A/(?:embed|shorts|live|v)/(?<id>#{YOUTUBE_ID})},
    %r{\A/watch\?(?:.*&)?v=(?<id>#{YOUTUBE_ID})},
    %r{\A/(?<id>#{YOUTUBE_ID})\z}
  ].freeze

  VIMEO_PATH_FORMS = [
    %r{\A/video/(?<id>#{VIMEO_ID})},
    # /123456789 e /123456789/abcdef (link privado) — o id e o primeiro numero.
    %r{\A/(?<id>#{VIMEO_ID})(?=/|\z)}
  ].freeze

  class << self
    # => { provider:, video_id:, embed_url:, watch_url: } — provider nil quando
    # a URL nao e de YouTube/Vimeo. Nao levanta excecao: quem chama decide o que
    # fazer (o model deixa a aula sem video e o editor mostra o campo vazio).
    def parse(url)
      uri = safe_uri(url)
      return empty_result if uri.nil?

      case uri.host
      when *YOUTUBE_HOSTS then from_youtube(uri)
      when *VIMEO_HOSTS then from_vimeo(uri)
      else empty_result
      end
    end

    # Para o preview do editor, onde URL errada deve falhar alto e dizer o motivo.
    def parse!(url)
      result = parse(url)
      return result if result[:provider]

      raise ArgumentError, "URL nao reconhecida como video do YouTube ou Vimeo: #{url}"
    end

    def supported?(url)
      !parse(url)[:provider].nil?
    end

    # URL de embed. YouTube vai pelo nocookie: o player sem cookie nao grava
    # watch history do aluno no video, o que importa numa plataforma de curso
    # onde o mesmo video mostra o competencia no mesmo dominio.
    def embed_url(provider, video_id)
      return nil if provider.blank? || video_id.blank?

      case provider
      when 'youtube' then "https://www.youtube-nocookie.com/embed/#{video_id}"
      when 'vimeo' then "https://player.vimeo.com/video/#{video_id}"
      end
    end

    private

    # `watch?v=ID` e a forma que as pessoas colam, e o id vem na QUERY — nao no
    # path. Ler o path sozinho (o jeito obvio) erra justamente nesse caso.
    def from_youtube(uri)
      id = id_from_path(uri.path) || id_from_query(uri.query)
      return empty_result if id.blank?

      build('youtube', id, "https://www.youtube.com/watch?v=#{id}")
    end

    def id_from_path(path)
      YOUTUBE_PATH_FORMS.filter_map { |form| path.to_s.match(form)&.[](:id) }.first
    end

    def id_from_query(query)
      value = CGI.parse(query.to_s)['v']&.first
      return nil unless YOUTUBE_ID_EXACT.match?(value.to_s)

      value
    end

    def from_vimeo(uri)
      id = VIMEO_PATH_FORMS.filter_map { |form| uri.path.to_s.match(form)&.[](:id) }.first
      return empty_result if id.blank?

      build('vimeo', id, "https://vimeo.com/#{id}")
    end

    def build(provider, id, watch_url)
      {
        provider: provider,
        video_id: id,
        embed_url: embed_url(provider, id),
        watch_url: watch_url
      }
    end

    def empty_result
      { provider: nil, video_id: nil, embed_url: nil, watch_url: nil }
    end

    # URI de quem digita "youtube.com/watch?v=..." sem protocolo colado.
    def safe_uri(url)
      value = url.to_s.strip
      return nil if value.empty?

      value = "https://#{value}" unless value.match?(%r{\Ahttps?://}i)

      URI.parse(value)
    rescue URI::InvalidURIError
      nil
    end
  end
end