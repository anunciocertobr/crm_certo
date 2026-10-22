# frozen_string_literal: true

require 'ipaddr'
require 'resolv'

module Sites
  # Busca a URL de um Site recém-cadastrado e extrai o <title> da página,
  # pro nome do card (igual ao que normalmente aparece na aba do navegador).
  # Busca uma URL que o USUÁRIO digitou — mesmo risco de SSRF que
  # Products::Connectors::Base já resolve pra importação de produtos; reusa
  # a mesma blindagem (DNS pinning, bloqueio de IP privado/interno,
  # follow_redirects: false) em vez de reimplementar.
  class TitleFetcherService
    HTTP_TIMEOUT = 5

    def self.call(url)
      new.call(url)
    end

    def call(url)
      pinned_ip = assert_public_url!(url)
      response = HTTParty.get(
        url,
        timeout: HTTP_TIMEOUT,
        follow_redirects: false,
        connection_adapter: Products::Connectors::PinnedAddressAdapter,
        pinned_ip: pinned_ip,
        headers: { 'User-Agent' => 'Mozilla/5.0 (compatible; AnuncioCertoBot/1.0)' }
      )

      title = Nokogiri::HTML(response.body).at_css('title')&.text&.strip
      title.presence || fallback_name(url)
    rescue StandardError => e
      Rails.logger.warn "Sites::TitleFetcherService: falha ao buscar título de #{url}: #{e.message}"
      fallback_name(url)
    end

    private

    def fallback_name(url)
      URI.parse(url).host.presence || url.to_s
    rescue URI::InvalidURIError
      url.to_s
    end

    def assert_public_url!(url)
      uri = URI.parse(url.to_s)
      raise ArgumentError, 'only http(s) URLs are allowed' unless %w[http https].include?(uri.scheme)
      raise ArgumentError, 'invalid host' if uri.host.blank?

      addresses = Resolv.getaddresses(uri.host)
      raise ArgumentError, "could not resolve #{uri.host}" if addresses.empty?
      raise ArgumentError, 'refusing to connect to a private/internal address' if addresses.any? { |a| Products::UrlSafety.private_ip?(a) }

      addresses.find { |addr| addr.exclude?(':') } || addresses.first
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      raise ArgumentError, 'invalid site URL'
    end
  end
end
