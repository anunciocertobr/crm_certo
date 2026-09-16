# frozen_string_literal: true

# Public::RealEstate::LeadCreationService
#
# Captura de lead anônima vinda do site público de imóveis, usada quando o
# imóvel está configurado com contato via formulário — em vez de WhatsApp
# direto — via Product#metadata['contact_mode'] (ver RealEstateController).
# Resolve (ou cria, no primeiro lead) o pipeline "Imobiliária" e delega a
# criação de fato do contact + pipeline_item pro mesmo
# Public::Leads::CreationService já usado pelos formulários de captura
# (B14.01), assim o lead aparece no CRM com a mesma cara de qualquer outro.
class Public::RealEstate::LeadCreationService
  PIPELINE_NAME = 'Imobiliária'
  DEFAULT_STAGE_NAME = 'Novos Leads'

  def initialize(product:, params:)
    @product = product
    @params = params
  end

  def perform
    pipeline, stage = resolve_pipeline_and_stage
    assigned_agent = Public::RealEstate::AgentAssignmentService.new(pipeline: pipeline).assign

    Public::Leads::CreationService.new(
      lead_params: {
        contact: {
          name: @params[:name],
          email: @params[:email],
          phone_number: @params[:phone]
        }.compact,
        deal: {
          pipeline_id: pipeline.id,
          stage_id: stage.id,
          title: "Imóvel: #{@product.name}"
        },
        custom_fields: {
          'product_id' => @product.id,
          'product_name' => @product.name,
          'message' => @params[:message],
          'assigned_agent_id' => assigned_agent&.dig('id'),
          'assigned_agent_name' => assigned_agent&.dig('name')
        }.compact,
        metadata: { lead_source: 'real_estate_site' }
      }
    ).perform
  end

  private

  def resolve_pipeline_and_stage
    pipeline = Pipeline.find_by(name: PIPELINE_NAME) || create_pipeline!
    stage = pipeline.pipeline_stages.order(:position).first || create_stage!(pipeline)
    [pipeline, stage]
  end

  def create_pipeline!
    Pipeline.create!(
      name: PIPELINE_NAME,
      pipeline_type: 'custom',
      scope: 'empresa',
      created_by: system_user,
      # visibility default é "private" (só o created_by enxerga) — como
      # quem cria este pipeline é um usuário de sistema (ver system_user),
      # sem isso nenhum atendente veria os leads do site de imóveis na
      # lista de Pipelines. "public" replica o mesmo acesso amplo que um
      # pipeline padrão (is_default) já tem.
      visibility: :public
    )
  end

  def create_stage!(pipeline)
    pipeline.pipeline_stages.create!(name: DEFAULT_STAGE_NAME, position: 0)
  end

  # Mesmo padrão usado em outros pontos do sistema pra atribuir uma ação
  # sem usuário autenticado (ver Whatsapp::EvolutionHandlers::MessagesUpsert).
  def system_user
    User.where(type: 'SuperAdmin').first || User.first
  end
end
