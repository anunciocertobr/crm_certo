# frozen_string_literal: true

# SiteLeadSubmissionSerializer — serialização de um evento recebido no
# webhook de um Site, pra tabela "Ver leads". Sempre inclui `raw_payload`
# (linha expansível no front) já que o payload do GTM é livre e as colunas
# fixas abaixo não cobrem necessariamente tudo que o cliente mandou.
module SiteLeadSubmissionSerializer
  extend self

  def serialize(submission)
    {
      id: submission.id,
      event_name: submission.event_name,
      name: submission.name,
      email: submission.email,
      phone: submission.phone,
      value: submission.value,
      currency: submission.currency,
      transaction_id: submission.transaction_id,
      product_ids: submission.product_ids || [],
      content_category: submission.content_category || [],
      content_name: submission.content_name || [],
      content_type: submission.content_type,
      num_items: submission.num_items,
      coupon: submission.coupon,
      first_name: submission.first_name,
      last_name: submission.last_name,
      external_id: submission.external_id,
      first_party_collection: submission.first_party_collection,
      customer_total_orders: submission.customer_total_orders,
      customer_total_order_value: submission.customer_total_order_value,
      payment_method: submission.payment_method,
      action_source: submission.action_source,
      gender: submission.gender,
      birth_date: submission.birth_date,
      address_city: submission.address_city,
      address_state: submission.address_state,
      address_zip: submission.address_zip,
      address_country: submission.address_country,
      page_url: submission.page_url,
      utm_source: submission.utm_source,
      utm_medium: submission.utm_medium,
      utm_campaign: submission.utm_campaign,
      utm_term: submission.utm_term,
      utm_content: submission.utm_content,
      utm_id: submission.utm_id,
      gclid: submission.gclid,
      fbclid: submission.fbclid,
      fbp: submission.fbp,
      fbc: submission.fbc,
      ttclid: submission.ttclid,
      msclkid: submission.msclkid,
      raw_payload: submission.raw_payload || {},
      created_at: submission.created_at&.iso8601
    }
  end
end
