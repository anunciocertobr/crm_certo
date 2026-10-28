# Identifica telefone/e-mail/nome nas perguntas de um formulário de Lead
# Ads pelo NOME do campo — formulários da Meta não têm um `type`
# estruturado pra isso, só o texto da pergunta que quem criou o formulário
# escolheu. Extraído de Meta::LeadAds::ImportService#parse_fields (que
# também passou a usar este módulo) pra ser reaproveitado por
# Api::V1::Admin::MetaLeadSubmissionsController — o nome/telefone do lead
# às vezes só existe aqui (field_data bruto), nunca no Contact do CRM (ex.:
# Contact nunca foi criado com telefone/nome corretos, ou o campo custom do
# formulário tinha um nome que `find_or_create_contact` não reconheceu na
# hora).
module Meta
  module LeadAds
    module FieldParser
      FIELD_NAME_PATTERNS = {
        phone: /telefone|celular|whatsapp|phone/i,
        email: /e-?mail/i,
        name: /nome|name/i
      }.freeze

      module_function

      def parse(field_data)
        parsed = {}
        Array(field_data).each do |f|
          field_name = f['name'].to_s
          value = Array(f['values']).first
          next if value.blank?

          FIELD_NAME_PATTERNS.each do |key, pattern|
            parsed[key] ||= value if field_name.match?(pattern)
          end
        end
        parsed
      end
    end
  end
end
