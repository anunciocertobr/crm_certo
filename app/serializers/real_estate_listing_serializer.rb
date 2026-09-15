# frozen_string_literal: true

# Serialização pública de um imóvel (Product com item_type "imovel") pra
# página pública de imóveis — ao contrário do ProductMenuSerializer (que só
# expõe a primeira imagem), aqui a galeria completa (fotos + vídeos) vai
# junto, porque o modal de detalhes do imóvel mostra todas.
module RealEstateListingSerializer
  extend self

  # Chaves esperadas dentro de `metadata` — qualquer uma ausente vira nil,
  # nunca quebra a serialização (imóvel cadastrado sem, por exemplo,
  # coordenadas ainda aparece na grade, só não no mapa).
  METADATA_FIELDS = %w[
    tags estado cidade bairro endereco numero cep
    quartos banheiros vagas suites perto_metro condominio iptu vantagens
    latitude longitude contact_mode
  ].freeze

  def serialize(product)
    metadata = product.metadata || {}

    base = {
      id: product.id,
      name: product.name,
      description: product.description,
      price: product.default_price.to_f,
      currency: product.currency,
      media: product.serialized_media
    }

    METADATA_FIELDS.each_with_object(base) do |field, hash|
      hash[field.to_sym] = metadata[field]
    end
  end

  def serialize_collection(products)
    products.map { |p| serialize(p) }
  end
end
