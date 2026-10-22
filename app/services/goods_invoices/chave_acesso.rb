# Chave de acesso da NF-e/NFC-e: 44 dígitos (cUF + AAMM + CNPJ + mod + série
# + número + tpEmis + cNF aleatório + DV), módulo 11 no dígito verificador.
# Estrutura e algoritmo bem documentados/padronizados nacionalmente (ao
# contrário do NFS-e municipal) — não é específico de nenhum estado.
module GoodsInvoices
  class ChaveAcesso
    CODIGO_UF = {
      'AC' => '12', 'AL' => '27', 'AP' => '16', 'AM' => '13', 'BA' => '29',
      'CE' => '23', 'DF' => '53', 'ES' => '32', 'GO' => '52', 'MA' => '21',
      'MT' => '51', 'MS' => '50', 'MG' => '31', 'PA' => '15', 'PB' => '25',
      'PR' => '41', 'PE' => '26', 'PI' => '22', 'RJ' => '33', 'RN' => '24',
      'RS' => '43', 'RO' => '11', 'RR' => '14', 'SC' => '42', 'SP' => '35',
      'SE' => '28', 'TO' => '17'
    }.freeze

    def self.gerar(uf:, data_emissao:, cnpj:, modelo:, serie:, numero:, tipo_emissao: '1')
      new(uf: uf, data_emissao: data_emissao, cnpj: cnpj, modelo: modelo, serie: serie,
          numero: numero, tipo_emissao: tipo_emissao).gerar
    end

    def initialize(uf:, data_emissao:, cnpj:, modelo:, serie:, numero:, tipo_emissao: '1')
      @uf = uf
      @data_emissao = data_emissao
      @cnpj = cnpj.to_s.gsub(/\D/, '')
      @modelo = modelo.to_s
      @serie = serie.to_s
      @numero = numero.to_s
      @tipo_emissao = tipo_emissao.to_s
    end

    def gerar
      codigo_numerico = format('%08d', SecureRandom.random_number(10**8))
      chave_sem_dv = [
        CODIGO_UF.fetch(@uf.to_s.upcase),
        @data_emissao.strftime('%y%m'),
        @cnpj.rjust(14, '0'),
        @modelo.rjust(2, '0'),
        @serie.rjust(3, '0'),
        @numero.rjust(9, '0'),
        @tipo_emissao,
        codigo_numerico
      ].join

      chave_sem_dv + digito_verificador(chave_sem_dv).to_s
    end

    private

    # Módulo 11, pesos de 2 a 9 ciclando da direita pra esquerda. Resto 0 ou 1
    # => DV 0; senão DV = 11 - resto.
    def digito_verificador(chave)
      soma = chave.chars.reverse.each_with_index.sum do |digito, index|
        peso = 2 + (index % 8)
        digito.to_i * peso
      end
      resto = soma % 11
      resto < 2 ? 0 : 11 - resto
    end
  end
end
