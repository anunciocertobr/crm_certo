# frozen_string_literal: true

# Courses::PasswordDigest - PBKDF2-HMAC-SHA256 para a senha da area de cursos.
#
# Não há bcrypt no bundle (nem devise), e a senha do aluno não sai daqui: o que
# fica gravado é o digest, no formato
#
#   pbkdf2$<iterations>$<salt hex>$<hash hex>
#
# Guardar o iterador e o salt dentro do valor é o que permite trocar a
# quantidade de iterações depois sem invalidar as senhas já criadas: a verificação
# usa os parâmetros que vieram junto.
module Courses::PasswordDigest
  ITERATIONS = 210_000
  SALT_BYTES = 16
  DIGEST_BYTES = 32
  PREFIX = 'pbkdf2'

  module_function

  def digest(password, salt = SecureRandom.random_bytes(SALT_BYTES), iterations: ITERATIONS)
    hash = derive(password, salt, iterations)
    "#{PREFIX}$#{iterations}$#{salt.unpack1('H*')}$#{hash.unpack1('H*')}"
  end

  # true/false. Qualquer coisa malformada no valor gravado é `false`: um digest
  # antigo não pode ser confundido com "senha errada" — e nunca pode estourar
  # exceção no meio de um request de login.
  def verify(password, encoded)
    parts = encoded.to_s.split('$')
    return false unless parts.size == 4 && parts[0] == PREFIX

    iterations = Integer(parts[1], exception: false)
    return false if iterations.nil? || iterations < 1

    salt = hex_to_bin(parts[2])
    expected = hex_to_bin(parts[3])
    return false if salt.nil? || expected.nil? || expected.empty?

    actual = derive(password, salt, iterations)
    ActiveSupport::SecurityUtils.secure_compare(expected, actual)
  end

  def derive(password, salt, iterations)
    OpenSSL::KDF.pbkdf2_hmac(
      password.to_s,
      salt: salt,
      iterations: iterations,
      length: DIGEST_BYTES,
      hash: 'SHA256'
    )
  end

  def hex_to_bin(value)
    return nil unless value.to_s.match?(/\A[0-9a-f]*\z/i)
    return nil if value.to_s.length.odd?

    [value].pack('H*')
  end
end