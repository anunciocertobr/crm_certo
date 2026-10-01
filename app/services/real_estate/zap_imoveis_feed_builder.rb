# frozen_string_literal: true

# Monta o feed XML no formato VrSync — formato único que a ZAP Imóveis, Viva
# Real e OLX passaram a exigir (mesmo arquivo serve os três portais). Schema
# oficial: https://developers.grupozap.com/feeds/vrsync/elements/listing.html
#
# A imobiliária cola a URL deste feed (Public::Api::V1::RealEstateController
# #zap_feed) no Canal Pro (painel da ZAP) uma vez; dali em diante o portal
# relê o arquivo sozinho a cada ~12h — não existe "republicar", só manter
# o XML atualizado.
module RealEstate
  class ZapImoveisFeedBuilder
    # Valores aceitos pelo elemento <PropertyType> — lista oficial tem mais
    # (comercial, agrícola etc.), mas o cadastro de imóvel deste CRM só cobre
    # os tipos residenciais mais comuns; adicionar aqui + no Select do
    # frontend (RealEstateItemModal.tsx) quando precisar de mais um.
    PROPERTY_TYPES = {
      'apartamento' => 'Residential / Apartment',
      'casa' => 'Residential / Home',
      'condominio' => 'Residential / Condo',
      'sobrado' => 'Residential / Sobrado',
      'cobertura' => 'Residential / Penthouse',
      'kitnet' => 'Residential / Kitnet',
      'studio' => 'Residential / Studio',
      'loft' => 'Residential / Loft',
      'terreno' => 'Residential / Land Lot'
    }.freeze

    TRANSACTION_TYPES = {
      'venda' => 'For Sale',
      'aluguel' => 'For Rent',
      'venda_aluguel' => 'Sale/Rent'
    }.freeze

    # Regras mínimas do próprio schema VrSync — um imóvel que não bate essas
    # exigências é recusado pelo portal de qualquer forma, então nem entra no
    # XML (silenciosamente pior que listar errado e o portal rejeitar o
    # arquivo inteiro). Ver #skip_reason.
    MIN_PHOTOS = 5
    MIN_DESCRIPTION_LENGTH = 50
    MAX_DESCRIPTION_LENGTH = 3000

    def self.build
      new.build
    end

    def build
      products = Product.active.by_item_type('imovel').order(:name)

      builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.ListingDataFeed(
          'xmlns' => 'http://www.vivareal.com/schemas/1.0/VRSync',
          'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
          'xsi:schemaLocation' => 'http://www.vivareal.com/schemas/1.0/VRSync http://xml.vivareal.com/vrsync.xsd'
        ) do
          build_header(xml)
          xml.Listings do
            products.each do |product|
              reason = skip_reason(product)
              if reason
                Rails.logger.warn "RealEstate::ZapImoveisFeedBuilder: pulando imóvel #{product.id} (#{product.name}): #{reason}"
                next
              end

              build_listing(xml, product)
            end
          end
        end
      end

      builder.to_xml
    end

    private

    def build_header(xml)
      xml.Header do
        xml.Provider(GlobalConfigService.load('REAL_ESTATE_COMPANY_NAME', 'Imobiliária'))
        xml.Email(GlobalConfigService.load('ZAP_CONTACT_EMAIL', ''))
        xml.ContactName(GlobalConfigService.load('REAL_ESTATE_COMPANY_NAME', 'Imobiliária'))
        xml.PublishDate(Time.current.strftime('%Y-%m-%dT%H:%M:%S'))
      end
    end

    # Condições mínimas pro portal aceitar o imóvel — qualquer uma ausente faz
    # a ZAP recusar o XML inteiro nalguns casos, não só o imóvel em questão,
    # então é mais seguro pular aqui do que mandar um Listing incompleto.
    def skip_reason(product)
      metadata = product.metadata || {}
      return 'sem preço (default_price)' if product.default_price.to_f <= 0
      return 'descrição ausente ou curta demais (mínimo 50 caracteres)' if product.description.to_s.strip.length < MIN_DESCRIPTION_LENGTH
      return 'sem transaction_type (venda/aluguel) no metadata' unless TRANSACTION_TYPES.key?(metadata['transaction_type'])
      return 'sem property_type no metadata' unless PROPERTY_TYPES.key?(metadata['property_type'])
      return 'sem cidade/bairro/estado no metadata' if metadata['cidade'].blank? || metadata['bairro'].blank? || metadata['estado'].blank?

      photo_count = product.serialized_media.count { |m| m[:kind] == 'image' }
      return "menos de #{MIN_PHOTOS} fotos (tem #{photo_count})" if photo_count < MIN_PHOTOS

      nil
    end

    def build_listing(xml, product)
      metadata = product.metadata || {}

      xml.Listing do
        xml.ListingID(product.id)
        xml.Title(product.name.to_s.truncate(100))
        xml.TransactionType(TRANSACTION_TYPES.fetch(metadata['transaction_type']))
        xml.PublicationType('STANDARD')
        build_media(xml, product)
        build_details(xml, product, metadata)
        build_location(xml, metadata)
        build_contact_info(xml)
      end
    end

    def build_media(xml, product)
      xml.Media do
        product.serialized_media.each_with_index do |item, index|
          if item[:kind] == 'video'
            xml.Item(item[:url], medium: 'video')
          else
            attrs = { medium: 'image' }
            attrs[:primary] = 'true' if index.zero?
            xml.Item(full_media_url(item[:url]), **attrs)
          end
        end
      end
    end

    # `serialized_media` devolve path relativo pros uploads do próprio CRM
    # (Active Storage, `only_path: true`) — a ZAP baixa a imagem direto do
    # XML, então precisa de URL absoluta; links externos (`source: 'url'`)
    # já vêm absolutos e passam direto.
    def full_media_url(url)
      return url if url.start_with?('http://', 'https://')

      opts = Rails.application.routes.default_url_options
      protocol = opts[:protocol] || 'https'
      port = opts[:port]
      port_part = port && ![80, 443].include?(port) ? ":#{port}" : ''
      "#{protocol}://#{opts[:host]}#{port_part}#{url}"
    end

    def build_details(xml, product, metadata)
      xml.Details do
        xml.UsageType('Residential')
        xml.PropertyType(PROPERTY_TYPES.fetch(metadata['property_type']))
        xml.Description { xml.cdata(product.description.to_s.truncate(MAX_DESCRIPTION_LENGTH)) }

        if metadata['transaction_type'] == 'aluguel'
          xml.RentalPrice(product.default_price.to_i, currency: 'BRL', period: 'Monthly')
        else
          xml.ListPrice(product.default_price.to_i, currency: 'BRL')
        end

        area = metadata['area_util'].to_f
        xml.LivingArea(area.to_i, unit: 'square metres') if area.positive?
        xml.PropertyAdministrationFee(metadata['condominio'].to_i, currency: 'BRL') if metadata['condominio'].present?
        xml.YearlyTax(metadata['iptu'].to_i, currency: 'BRL') if metadata['iptu'].present?
        xml.Bedrooms(metadata['quartos'].to_i) if metadata['quartos'].present?
        xml.Bathrooms(metadata['banheiros'].to_i) if metadata['banheiros'].present?
        xml.Suites(metadata['suites'].to_i) if metadata['suites'].present?
        xml.Garage(metadata['vagas'].to_i, type: 'Parking Space') if metadata['vagas'].present?
      end
    end

    def build_location(xml, metadata)
      xml.Location(displayAddress: 'Street') do
        xml.Country('Brasil', abbreviation: 'BR')
        estado = metadata['estado'].to_s
        xml.State(estado, abbreviation: estado.length == 2 ? estado.upcase : '')
        xml.City(metadata['cidade'])
        xml.Neighborhood(metadata['bairro'])
        xml.Address(metadata['endereco']) if metadata['endereco'].present?
        xml.StreetNumber(metadata['numero']) if metadata['numero'].present?
        xml.PostalCode(metadata['cep'].to_s.gsub(/\D/, '')) if metadata['cep'].present?
        xml.Latitude(metadata['latitude']) if metadata['latitude'].present?
        xml.Longitude(metadata['longitude']) if metadata['longitude'].present?
      end
    end

    def build_contact_info(xml)
      xml.ContactInfo do
        xml.Name(GlobalConfigService.load('REAL_ESTATE_COMPANY_NAME', 'Imobiliária'))
        xml.Email(GlobalConfigService.load('ZAP_CONTACT_EMAIL', ''))
      end
    end
  end
end
