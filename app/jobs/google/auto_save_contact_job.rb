# Disparado por Contact#auto_save_to_google_contacts quando
# GOOGLE_CONTACTS_AUTO_SAVE está ligado (Contatos > Contatos Google) — cria
# o contato recém-chegado no Google Contatos sem precisar do fluxo manual
# de diff + "Adicionar ao Google" já existente.
module Google
  class AutoSaveContactJob < ApplicationJob
    queue_as :low

    def perform(contact_id)
      contact = Contact.find_by(id: contact_id)
      return if contact.blank?

      service = Google::ContactsService.new
      return unless service.connected?

      result = service.create_contact(name: contact.name.presence || 'Sem nome', phone: contact.phone_number, email: contact.email)
      Rails.logger.error "Google::AutoSaveContactJob: failed for contact=#{contact_id}: #{result.error}" unless result.success
    end
  end
end
