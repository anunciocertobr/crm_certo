# frozen_string_literal: true

# Sessão compartilhada única do Facebook usada pela automação de cobrança
# (PIX/boleto) de saldo pré-pago do Meta Ads — ver MetaBillingSession e
# Meta::Billing::BrowserSession. Não existe endpoint público da Meta pra
# gerar essa cobrança; a automação roda um navegador real, e essa sessão
# vem de cookies IMPORTADOS de um navegador já logado (export do
# Cookie-Editor), nunca de email/senha digitados — ver
# Meta::Billing::CookieImportService.
class Api::V1::Meta::BillingSessionsController < Api::V1::BaseController
  def show
    session = MetaBillingSession.instance
    render json: session_json(session)
  end

  def import_cookies
    session = MetaBillingSession.instance
    result = Meta::Billing::CookieImportService.call(raw_json: params.require(:cookies_json))

    if result.success
      session.update!(
        cookies_encrypted: result.data,
        status: 'active',
        cookies_imported_at: Time.current,
        last_verified_at: nil,
        last_error: nil
      )
      render json: session_json(session)
    else
      render json: { error: result.error }, status: :unprocessable_entity
    end
  end

  private

  def session_json(session)
    {
      status: session.status,
      cookiesImportedAt: session.cookies_imported_at,
      lastVerifiedAt: session.last_verified_at,
      lastError: session.last_error,
      hasCookies: session.cookies_encrypted.present?
    }
  end
end
