# frozen_string_literal: true

# Leitura PÚBLICA do relatório de um link: sem sessão e sem API key — a
# credencial É o token da URL. Mesmo padrão dos painéis públicos já
# existentes (Public::Api::V1::MetaClient::GrantsController).
#
# A RESTRIÇÃO DE CONTAS É APLICADA AQUI, NO SERVIDOR. Filtrar no front não
# restringe nada: qualquer pessoa com o link trocaria a chamada por um
# cliente qualquer do devtools e leria as metas das outras contas.
class Public::Api::V1::ReportLinksController < PublicController
  # GET /public/api/v1/report_links/:token
  def show
    link = ReportSnapshot.find_by(token: params[:token].to_s)

    if link.nil?
      render json: { success: false, error: 'Link inválido' }, status: :not_found
    elsif !link.usable?
      render json: { success: false, error: 'Este link expirou ou foi revogado.' }, status: :gone
    else
      render json: { success: true, data: build_payload(link) }
    end
  end

  private

  def build_payload(link)
    {
      link: {
        title: link.title,
        report_type: link.report_type,
        expires_at: link.expires_at&.iso8601,
        days_left: link.days_left
      }
    }.merge(link.ads_report? ? ads_reports_payload(link) : { goals: scoped_goals(link).filter_map { |g| visible_goal(g, link) } })
  end

  # Relatório de anúncios: o serviço decide quais chamadas fazer, sempre a
  # partir das contas gravadas no link. Datas vêm do visitante (a página deixa
  # escolher o período) e são normalizadas com teto dentro do serviço.
  def ads_reports_payload(link)
    outcome = AdsReportsPayload.call(
      link,
      date_start: params[:date_start],
      date_stop: params[:date_stop]
    )

    return { error: outcome.error } unless outcome.success

    { report: outcome.data }
  end

  def visible_goal(goal, link)
    serialized = MarketingClientGoalSerializer.serialize(
      goal,
      ad_account_ids: link.ad_account_ids,
      include_changelog: false
    )
    # Meta que ficou sem nenhuma conta visível NÃO entra na resposta: sem
    # esta linha, o nome do cliente, os segmentos e o meta_budget dela
    # vazariam pelo link de outro cliente.
    serialized if serialized[:ad_accounts].any?
  end

  def scoped_goals(link)
    scope = MarketingClientGoal.active
    ids = link.client_goal_ids
    scope = scope.where(id: ids) if ids.any?
    scope.order(created_at: :desc)
  end
end