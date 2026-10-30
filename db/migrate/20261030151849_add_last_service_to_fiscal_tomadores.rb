# Dados do SERVIÇO da última nota emitida pra este tomador (discriminação,
# código de serviço municipal, código NBS, código de tributação, valor,
# alíquota ISS) — pedido do usuário pra, ao escolher um tomador salvo, o
# formulário de emissão vir TODO preenchido (não só nome/endereço, que já
# era salvo). Mesmo formato de campos do ServiceInvoiceFormData, pra o
# front copiar direto sem mapear campo a campo (igual já faz com `endereco`).
class AddLastServiceToFiscalTomadores < ActiveRecord::Migration[7.1]
  def change
    add_column :fiscal_tomadores, :last_service, :jsonb, null: false, default: {}
  end
end
