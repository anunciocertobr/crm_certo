# frozen_string_literal: true

module Public
  # Serve a página do relatório compartilhado (o mesmo HTML do Dashboard) sem
  # sessão e sem Personal Access Token. É a contraparte de
  # Public::Api::V1::Reports::* — a página fica na API e o nginx do CRM
  # apenas aponta /r/ para cá, mantendo a URL no domínio do app Android.
  #
  # Tudo que a página mostra sai das rotas /public/api/..., que autenticam pelo
  # mesmo token e validam expiração/revogação a cada chamada.
  class ReportPagesController < PublicController
    # GET /public/r/:token
    def show
      link = ReportSnapshot.find_by(token: params[:token].to_s)
      return render_gone if link.nil? || !link.usable?

      html = ReportHtml.new(link).call

      # Página personalized por link: nunca pode ficar em cache compartilhado,
      # e o token está na URL, então não sai para Referer de terceiros.
      response.headers['Cache-Control'] = 'private, no-store'
      response.headers['Referrer-Policy'] = 'no-referrer'
      response.headers['X-Robots-Tag'] = 'noindex, nofollow'

      render html: html.html_safe, content_type: 'text/html; charset=utf-8'
    rescue Public::ReportHtml::RenderError => e
      # Falhou a proteção contra vazamento de segredo: a página NÃO é servida.
      Rails.logger.error("[Public::ReportPagesController] relatório não renderizado: #{e.message}")
      render plain: 'Relatório indisponível.', status: :internal_server_error
    end

    private

    def render_gone
      render plain: 'Este link expirou ou foi revogado.', status: :gone
    end
  end
end