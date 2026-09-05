# Lista TODAS as páginas do Facebook que o login já usado no CRM administra
# (via GET /me/accounts), não só as que já viraram canal aqui — igual ao
# padrão de accessible_customers do Google Ads. Usa o user_access_token de
# qualquer Channel::FacebookPage já conectado (todos vêm do mesmo login do
# Facebook, então qualquer um serve pra listar as demais páginas).
class Facebook::AccessiblePagesService
  class Error < StandardError; end

  FIELDS = 'id,name,access_token,instagram_business_account{id,username,profile_picture_url}'.freeze

  # Retorna cada página com page_id/name/instagram (se vinculado) e se já
  # existe como Channel::FacebookPage aqui.
  def accessible_pages
    pages = fetch_pages

    pages.map do |page|
      {
        page_id: page['id'],
        name: page['name'],
        instagram: page['instagram_business_account'] && {
          id: page['instagram_business_account']['id'],
          username: page['instagram_business_account']['username'],
          profile_picture_url: page['instagram_business_account']['profile_picture_url']
        },
        connected: Channel::FacebookPage.exists?(page_id: page['id'])
      }
    end
  end

  # Cria o Channel::FacebookPage (+ Inbox) pra uma página acessível que ainda
  # não foi conectada — mesmo fluxo de app/controllers/api/v1/callbacks_controller.rb#register_facebook_page,
  # só que disparado a partir do Gestor de Posts em vez de Configurações > Canais.
  def connect(page_id)
    existing = Channel::FacebookPage.find_by(page_id: page_id)
    return existing if existing

    page = fetch_pages.find { |p| p['id'] == page_id }
    raise Error, 'Página não encontrada ou sem permissão de acesso.' if page.blank?

    channel = nil
    ActiveRecord::Base.transaction do
      channel = Channel::FacebookPage.create!(
        page_id: page['id'],
        user_access_token: user_access_token,
        page_access_token: page['access_token'],
        instagram_id: page.dig('instagram_business_account', 'id')
      )
      inbox = Inbox.create!(name: page['name'], channel: channel)
      Avatar::AvatarFromUrlJob.perform_later(inbox, "https://graph.facebook.com/#{page['id']}/picture?type=large")
    end
    channel
  end

  private

  def fetch_pages
    token = user_access_token
    raise Error, 'Conecte ao menos uma página do Facebook em Configurações > Canais antes.' if token.blank?

    Koala::Facebook::API.new(token).get_connections('me', 'accounts', fields: FIELDS) || []
  rescue Koala::Facebook::AuthenticationError, Koala::Facebook::ClientError => e
    raise Error, "Falha ao consultar o Facebook: #{e.message}"
  end

  def user_access_token
    Channel::FacebookPage.where.not(user_access_token: nil).first&.user_access_token
  end
end
