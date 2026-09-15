# frozen_string_literal: true

# Anonymous, public real-estate listing page — lista os imóveis ativos
# (item_type "imovel"). Mesmo padrão do Public::Api::V1::MenuController
# (herda PublicController direto, sem API key — uma instalação, um site,
# sem slug pra resolver). Sem agrupar por categoria: filtro por
# tag/estado/cidade é client-side, a partir da lista completa, igual o
# protótipo de referência (~/Desktop/imobiliaria) já fazia com os dados
# vindos de planilha.
class Public::Api::V1::RealEstateController < PublicController
  # GET /public/api/v1/real_estate
  def show
    listings = Product.active.by_item_type('imovel').order(:name)

    render json: {
      success: true,
      data: {
        listings: RealEstateListingSerializer.serialize_collection(listings),
        settings: display_settings
      }
    }
  end

  private

  # Aparência configurável em Organização > Imobiliária, mais o número de
  # WhatsApp usado no botão "Falar sobre este imóvel" de cada card — o
  # contato é um link wa.me aberto no navegador do visitante, não passa
  # pelo backend (ao contrário do pedido do Cardápio Digital).
  def display_settings
    {
      company_name: GlobalConfigService.load('REAL_ESTATE_COMPANY_NAME', nil),
      header_color: GlobalConfigService.load('REAL_ESTATE_HEADER_COLOR', nil),
      background_color: GlobalConfigService.load('REAL_ESTATE_BACKGROUND_COLOR', nil),
      footer_color: GlobalConfigService.load('REAL_ESTATE_FOOTER_COLOR', nil),
      icon_color: GlobalConfigService.load('REAL_ESTATE_ICON_COLOR', nil),
      text_color: GlobalConfigService.load('REAL_ESTATE_TEXT_COLOR', nil),
      title_color: GlobalConfigService.load('REAL_ESTATE_TITLE_COLOR', nil),
      company_name_color: GlobalConfigService.load('REAL_ESTATE_COMPANY_NAME_COLOR', nil),
      gtm_id: GlobalConfigService.load('REAL_ESTATE_GTM_ID', nil),
      whatsapp_number: GlobalConfigService.load('REAL_ESTATE_WHATSAPP_NUMBER', nil)
    }
  end
end
