require 'net/http'
require 'uri'
require 'json'

# Sobe um vídeo pro TikTok via Content Posting API (Direct Post), conta
# conectada em Configurações > Integrações > TikTok. Protocolo em 3 passos:
#   1. POST /v2/post/publish/creator_info/query/ — pega privacy_level_options
#      válidas pra ESTA conta (a Content Posting API exige escolher um dos
#      valores que ela mesma devolve, não um valor fixo nosso).
#   2. POST /v2/post/publish/video/init/ — metadata do post, devolve
#      publish_id + upload_url (válida 1h).
#   3. PUT {upload_url} — binário do vídeo inteiro num PUT só (mesma
#      simplificação do Youtube::UploadService: os vídeos deste fluxo cabem
#      tranquilo num único chunk, sem precisar quebrar em partes).
#
# ⚠️ App ainda não aprovado pela TikTok (App Review): a Content Posting API
# recusa qualquer post que não seja privado pra apps não auditados
# (erro unaudited_client_can_only_post_to_private_accounts) — por isso o
# privacy_level NUNCA vem de escolha do usuário aqui, é sempre o primeiro
# valor privado que creator_info devolver (normalmente SELF_ONLY). Tirar essa
# trava exige ter o app aprovado primeiro.
#
# Não faz polling do status de processamento (POST /v2/post/publish/status/
# fetch/) — mesma simplificação do Youtube::UploadService, que também marca
# "published" assim que o upload é aceito, sem esperar o processamento real
# da plataforma terminar.
class Tiktok::UploadService
  class Error < StandardError; end

  CREATOR_INFO_URL = 'https://open.tiktokapis.com/v2/post/publish/creator_info/query/'
  INIT_URL = 'https://open.tiktokapis.com/v2/post/publish/video/init/'
  PRIVATE_LEVEL_FALLBACK_ORDER = %w[SELF_ONLY FOLLOWER_OF_CREATOR MUTUAL_FOLLOW_FRIENDS].freeze

  attr_reader :upload

  def initialize(upload:)
    @upload = upload
  end

  # Retorna o publish_id do post no TikTok.
  def publish!
    raise Error, 'Upload sem vídeo anexado.' unless upload.video.attached?

    token = access_token
    raise Error, 'Conexão com o TikTok não encontrada. Conecte em Configurações > Integrações.' if token.blank?

    privacy_level = resolve_private_privacy_level(token)
    publish_id, upload_url = init_upload(token, privacy_level)
    upload_binary(upload_url)

    upload.update!(privacy_level: privacy_level)
    upload.mark_published!(publish_id)
    publish_id
  end

  private

  def access_token
    Tiktok::TokenService.new.access_token
  end

  # Só aceita um valor que a própria TikTok já marca como PRIVADO — nunca um
  # nível público/de seguidores, mesmo que a conta não esteja numa restrição
  # de app não auditado no momento (a conta pode mudar de estado; o código
  # não deve depender disso).
  def resolve_private_privacy_level(token)
    uri = URI(CREATOR_INFO_URL)
    http = build_http(uri)
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json; charset=UTF-8'

    response = http.request(request)
    unless response.code.to_i == 200
      raise Error, "Falha ao consultar opções da conta TikTok (#{response.code}): #{response.body}"
    end

    options = Array(JSON.parse(response.body).dig('data', 'privacy_level_options'))
    private_option = PRIVATE_LEVEL_FALLBACK_ORDER.find { |lvl| options.include?(lvl) } || options.find { |lvl| lvl != 'PUBLIC_TO_EVERYONE' }
    raise Error, 'A conta TikTok não tem nenhuma opção de privacidade privada disponível.' if private_option.blank?

    private_option
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao consultar a conta TikTok.'
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da TikTok (creator_info): #{e.message}"
  end

  def init_upload(token, privacy_level)
    size = upload.video.blob.byte_size
    uri = URI(INIT_URL)
    http = build_http(uri)
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json; charset=UTF-8'
    request.body = {
      post_info: {
        title: upload.title,
        privacy_level: privacy_level,
        disable_duet: false,
        disable_comment: false,
        disable_stitch: false
      },
      source_info: {
        source: 'FILE_UPLOAD',
        video_size: size,
        chunk_size: size,
        total_chunk_count: 1
      }
    }.to_json

    response = http.request(request)
    unless response.code.to_i == 200
      raise Error, "Falha ao iniciar upload no TikTok (#{response.code}): #{response.body}"
    end

    data = JSON.parse(response.body)['data'] || {}
    publish_id = data['publish_id']
    upload_url = data['upload_url']
    raise Error, 'Resposta sem publish_id/upload_url.' if publish_id.blank? || upload_url.blank?

    [publish_id, upload_url]
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao iniciar o upload no TikTok.'
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da TikTok (init): #{e.message}"
  end

  def upload_binary(upload_url)
    size = upload.video.blob.byte_size
    uri = URI(upload_url)
    http = build_http(uri, read_timeout: 600)
    request = Net::HTTP::Put.new(uri.request_uri)
    request['Content-Type'] = upload.video.blob.content_type.presence || 'video/mp4'
    request['Content-Range'] = "bytes 0-#{size - 1}/#{size}"
    request.body = upload.video.download

    response = http.request(request)
    return if response.code.to_i.between?(200, 299)

    raise Error, "Falha no upload do vídeo pro TikTok (#{response.code}): #{response.body}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado durante o upload do vídeo no TikTok.'
  end

  def build_http(uri, read_timeout: 30)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = read_timeout
    http
  end
end
