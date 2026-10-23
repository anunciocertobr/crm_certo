# frozen_string_literal: true

# Valida e normaliza um export do Cookie-Editor (extensão do Chrome) pros
# cookies de facebook.com, pra alimentar MetaBillingSession#cookies_encrypted.
# Nunca recebemos email/senha — só uma sessão já autenticada que um humano
# exportou do próprio navegador logado. Ver Api::V1::Meta::BillingSessionsController.
class Meta::Billing::CookieImportService
  Result = Struct.new(:success, :data, :error, keyword_init: true)

  # Cookies que só existem numa sessão de verdade logada — sem eles, o
  # export não serve pra nada (ex.: usuário exportou de uma aba deslogada).
  REQUIRED_COOKIE_NAMES = %w[c_user xs].freeze

  def self.call(...) = new(...).call

  def initialize(raw_json:)
    @raw_json = raw_json
  end

  def call
    parsed = parse(@raw_json)
    return Result.new(success: false, error: parsed[:error]) unless parsed[:ok]

    facebook_cookies = filter_facebook_cookies(parsed[:cookies])
    return Result.new(success: false, error: 'Nenhum cookie de facebook.com encontrado no arquivo.') if facebook_cookies.empty?

    missing = REQUIRED_COOKIE_NAMES - facebook_cookies.map { |c| c['name'] }
    if missing.any?
      return Result.new(
        success: false,
        error: "Isso não parece uma sessão logada (faltam os cookies #{missing.join(', ')}). " \
               'Confira se exportou numa aba com o facebook.com já logado.'
      )
    end

    Result.new(success: true, data: normalize(facebook_cookies).to_json)
  end

  private

  def parse(raw_json)
    data = JSON.parse(raw_json)
    return { ok: false, error: 'O arquivo precisa ser uma lista de cookies (export do Cookie-Editor).' } unless data.is_a?(Array)

    { ok: true, cookies: data }
  rescue JSON::ParserError
    { ok: false, error: 'Não consegui ler esse conteúdo como JSON. Cole exatamente o que o Cookie-Editor exportou.' }
  end

  def filter_facebook_cookies(cookies)
    cookies.select do |c|
      c.is_a?(Hash) && c['name'].present? && c['value'].present? &&
        c['domain'].to_s.delete_prefix('.').end_with?('facebook.com')
    end
  end

  # Guarda só o que o Ferrum precisa pra recriar os cookies depois
  # (Meta::Billing::BrowserSession) — descarta metadados do Cookie-Editor
  # que não usamos (storeId, hostOnly etc.).
  def normalize(cookies)
    cookies.map do |c|
      {
        'name' => c['name'],
        'value' => c['value'],
        'domain' => c['domain'],
        'path' => c['path'].presence || '/',
        'expires' => c['expirationDate'],
        'httpOnly' => !!c['httpOnly'],
        'secure' => !!c['secure'],
        'sameSite' => c['sameSite']
      }
    end
  end
end
