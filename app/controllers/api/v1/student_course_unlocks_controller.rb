# frozen_string_literal: true

# Senha do ALUNO para entrar na area de cursos.
#
# Fluxo: o aluno abre /cursos, nao tem senha -> escolhe uma (primeira vez);
# depois so destrava. Guardamos o digest no servidor e o cliente guarda o token
# de sessao, entao a senha em si nunca trafega de novo.
class Api::V1::StudentCourseUnlocksController < Api::V1::BaseController
  UNLOCK_PURPOSE = :course_unlock
  # GET: o cliente pergunta "preciso da senha?" antes de montar a area.
  def show
    unlock = current_unlock

    success_response(
      data: {
        required: true,
        configured: unlock.present?,
        unlocked: unlocked?,
        failed_attempts: unlock&.failed_attempts.to_i,
        locked: unlock&.locked? || false
      },
      message: 'Unlock status retrieved successfully'
    )
  end

  # POST { password: '...' } — cria ou troca a senha do aluno.
  def create
    password = params[:password].to_s
    if password.length < 4
      return error_response(ApiErrorCodes::VALIDATION_ERROR, 'Password is too short',
                            details: { min_length: 4 }, status: :unprocessable_entity)
    end

    unlock = current_unlock || StudentCourseUnlock.new(user_id: current_user.id)
    unlock.set_password(password)
    unlock.save!

    success_response(
      data: { configured: true, unlocked: true },
      message: 'Password saved',
      status: :created
    )
  end

  # POST { unlock_token: '...' } — destrava a area com a senha que ele ja definiu.
  def verify
    unlock = current_unlock
    # NUNCA INVALID_CREDENTIALS aqui: o frontend tratou esse codigo como
    # "sessao morta" e encerra o login do usuario (services/core/api.ts). Senha
    # errada da area de cursos nao e falha de autenticacao do CRM.
    return error_response(ApiErrorCodes::INVALID_INPUT, 'Password not configured yet', status: :unprocessable_entity) if unlock.nil?
    return error_response(ApiErrorCodes::FORBIDDEN, 'Too many failed attempts', status: :forbidden) if unlock.locked?

    if unlock.authenticate(params[:password].to_s)
      unlock.register_success!

      return success_response(
        data: { unlocked: true, token: unlock_token },
        message: 'Unlocked'
      )
    end

    unlock.register_failure!

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'Wrong password',
      details: { failed_attempts: unlock.failed_attempts, locked: unlock.locked? },
      status: :forbidden
    )
  end

  private

  def current_unlock
    @current_unlock ||= StudentCourseUnlock.find_by(user_id: current_user.id)
  end

  # O token que o cliente guarda para pular a tela de senha. Assinado com a
  # chave da aplicacao: nao ha tabela de sessoes, e o token nao serve para nada
  # alem de destravar a area de cursos.
  def unlock_token
    course_unlock_verifier.generate({ 'uid' => current_user.id, 'at' => Time.current.to_i },
                                     expires_in: 12.hours, purpose: UNLOCK_PURPOSE)
  end

  def unlocked?
    return false if current_unlock.nil?
    return false if params[:unlock_token].blank?

    payload = begin
      course_unlock_verifier.verified(params[:unlock_token].to_s, purpose: UNLOCK_PURPOSE)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    return false if payload.blank?

    payload['uid'].to_s == current_user.id.to_s
  end

  def course_unlock_verifier
    ActiveSupport::MessageVerifier.new(Rails.application.secret_key_base, digest: 'SHA256', serializer: JSON)
  end
end