# Lista de tomadores (clientes) salvos pra emissão de NFS-e — pedido do
# usuário pra não ter que redigitar nome/CPF-CNPJ/endereço toda vez que emite
# nota pra um cliente recorrente. `endereco` é jsonb com o MESMO formato de
# `ServiceInvoice#tomador_endereco` (logradouro/numero/bairro/codigo_municipio/
# uf/cep), pra o autopreenchimento no front ser uma cópia direta do objeto,
# sem mapear campo a campo.
class CreateFiscalTomadores < ActiveRecord::Migration[7.1]
  def change
    create_table :fiscal_tomadores, id: :uuid, default: -> { 'gen_random_uuid()' }, if_not_exists: true do |t|
      t.string :nome, null: false, limit: 255
      t.string :cpf_cnpj, null: false, limit: 20
      t.string :email, limit: 255
      t.jsonb :endereco, null: false, default: {}

      t.timestamps
    end

    add_index :fiscal_tomadores, :cpf_cnpj, unique: true, if_not_exists: true
    add_index :fiscal_tomadores, :nome, if_not_exists: true
  end
end
