# frozen_string_literal: true

# Contabilidade sinalizou 2 problemas numa NFS-e de Guarulhos (nº 279,
# emitida 19/10/2026): campo NBS não preenchido e código de tributação
# municipal sem campo próprio no formulário (dependia só da tabela
# hardcoded CODIGOS_TRIBUTACAO_MUNICIPIO em Guarulhos::Client).
#
# O manual técnico oficial de Guarulhos (v1.0, 14/10/2026 — publicado
# DIAS antes dessa nota) lista CodigoNbs como Ocorr. "1-1" (obrigatório)
# no bloco <Servico>, ao lado de ItemListaServico/CodigoTributacaoMunicipio.
# A nota 279 foi aceita sem ele, então a prefeitura ainda não está
# rejeitando por isso — mas o campo já é parte do schema publicado.
#
# codigo_tributacao_municipio aqui é OVERRIDE opcional: Guarulhos::Client
# já tem `invoice.respond_to?(:codigo_tributacao_municipio)` pronto pra
# usar essa coluna quando presente, caindo pro hash hardcoded só quando
# vier em branco — não precisa mexer nesse método de novo.
class AddNbsAndTributacaoOverrideToServiceInvoices < ActiveRecord::Migration[7.1]
  def change
    add_column :service_invoices, :codigo_nbs, :string
    add_column :service_invoices, :codigo_tributacao_municipio, :string
  end
end
