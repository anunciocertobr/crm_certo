# frozen_string_literal: true

# Falha de comunicação com um provedor de pagamento do cardápio digital
# (InfinitePay, Mercado Pago). Os clientes de cada provedor levantam
# subclasses desta, pra o controller tratar todas do mesmo jeito.
class DigitalMenu::CheckoutProviderError < StandardError; end
