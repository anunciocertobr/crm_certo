# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# Cobertura do ciclo de vida de pedidos do iFood (Ifood::Client +
# Api::V1::IfoodController) — sem isso, a integração inteira não tinha
# nenhum teste automatizado. Foco especial no motivo de cancelamento
# (ver fix f6f77b0): a homologação do iFood reprova um app que manda um
# `cancellationCode` fixo em vez de buscar os motivos válidos pra cada
# pedido — este spec trava essa regressão.
RSpec.describe 'Ifood orders lifecycle', type: :request do
  let(:base_url) { Ifood::Client::BASE_URL }
  let!(:user) { User.create!(name: 'Operador', email: "op-#{SecureRandom.hex(4)}@example.com") }

  let!(:order) do
    IfoodOrder.create!(
      ifood_order_id: 'ifood-order-123',
      display_id: '#123',
      status: 'PLACED',
      order_type: 'DELIVERY',
      customer_name: 'Cliente Teste',
      items: [{ 'name' => 'X-Burger', 'quantity' => 2 }],
      total_price: 45.9,
      placed_at: Time.current,
      raw_payload: {}
    )
  end

  def login_as(user)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = user
      Current.evo_permission_cache ||= {}
    end
  end

  before do
    login_as(user)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('IFOOD_CLIENT_ID', nil).and_return('client-id')
    allow(GlobalConfigService).to receive(:load).with('IFOOD_CLIENT_SECRET', nil).and_return('client-secret')
    allow(GlobalConfigService).to receive(:load).with('IFOOD_MERCHANT_ID', nil).and_return('merchant-1')

    stub_request(:post, "#{base_url}/authentication/v1.0/oauth/token")
      .to_return(status: 200, body: { accessToken: 'fake-token', expiresIn: 3600 }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  after { Current.reset }

  def json_response
    response.parsed_body
  end

  describe 'happy path: PLACED -> CONFIRMED -> PREPARATION_STARTED -> READY_TO_PICKUP -> DISPATCHED' do
    it 'calls the right iFood endpoint and mirrors the status locally at each step' do
      confirm_stub = stub_request(:post, "#{base_url}/order/v1.0/orders/#{order.ifood_order_id}/confirm")
                     .to_return(status: 202)
      post "/api/v1/ifood/orders/#{order.id}/confirm", as: :json
      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'status')).to eq('CONFIRMED')
      expect(confirm_stub).to have_been_requested

      prep_stub = stub_request(:post, "#{base_url}/order/v1.0/orders/#{order.ifood_order_id}/startPreparation")
                  .to_return(status: 202)
      post "/api/v1/ifood/orders/#{order.id}/start_preparation", as: :json
      expect(json_response.dig('data', 'status')).to eq('PREPARATION_STARTED')
      expect(prep_stub).to have_been_requested

      ready_stub = stub_request(:post, "#{base_url}/order/v1.0/orders/#{order.ifood_order_id}/readyToPickup")
                   .to_return(status: 202)
      post "/api/v1/ifood/orders/#{order.id}/ready_to_pickup", as: :json
      expect(json_response.dig('data', 'status')).to eq('READY_TO_PICKUP')
      expect(ready_stub).to have_been_requested

      dispatch_stub = stub_request(:post, "#{base_url}/order/v1.0/orders/#{order.ifood_order_id}/dispatch")
                      .to_return(status: 202)
      post "/api/v1/ifood/orders/#{order.id}/dispatch", as: :json
      expect(json_response.dig('data', 'status')).to eq('DISPATCHED')
      expect(dispatch_stub).to have_been_requested
    end
  end

  describe 'GET /api/v1/ifood/orders/:id/cancellation_reasons' do
    it "fetches the reasons valid for THIS order's current status from iFood (never a fixed list)" do
      stub_request(:get, "#{base_url}/order/v1.0/orders/#{order.ifood_order_id}/cancellationReasons")
        .to_return(
          status: 200,
          body: [
            { cancelCodeId: '501', description: 'Estabelecimento fechado' },
            { cancelCodeId: '507', description: 'Item em falta' }
          ].to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get "/api/v1/ifood/orders/#{order.id}/cancellation_reasons", as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to eq(
        [
          { 'cancelCodeId' => '501', 'description' => 'Estabelecimento fechado' },
          { 'cancelCodeId' => '507', 'description' => 'Item em falta' }
        ]
      )
    end
  end

  describe 'POST /api/v1/ifood/orders/:id/cancel' do
    it 'requires cancellation_code and reason — no more silently defaulting to a fixed code' do
      post "/api/v1/ifood/orders/#{order.id}/cancel", params: {}, as: :json

      # Request specs run through the exception-handling middleware, so the
      # missing param surfaces as an error response, not a raised exception —
      # what matters for this regression is that it's REJECTED (never silently
      # falls back to the old fixed '501' code) and the order stays untouched.
      expect(response).not_to have_http_status(:ok)
      expect(order.reload.status).to eq('PLACED')
    end

    it 'sends the EXACT cancellation_code/reason chosen by the operator to the iFood API' do
      cancel_stub = stub_request(:post, "#{base_url}/order/v1.0/orders/#{order.ifood_order_id}/requestCancellation")
                    .with(body: { reason: 'Item em falta', cancellationCode: '507' })
                    .to_return(status: 202)

      post "/api/v1/ifood/orders/#{order.id}/cancel",
           params: { cancellation_code: '507', reason: 'Item em falta' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response.dig('data', 'status')).to eq('CANCELLED')
      expect(cancel_stub).to have_been_requested
    end
  end

  describe 'when the iFood API itself rejects the action' do
    it 'surfaces a bad_gateway and does NOT change the local order status' do
      stub_request(:post, "#{base_url}/order/v1.0/orders/#{order.ifood_order_id}/confirm")
        .to_return(status: 409, body: { message: 'Order already confirmed' }.to_json)

      post "/api/v1/ifood/orders/#{order.id}/confirm", as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(order.reload.status).to eq('PLACED')
    end
  end

  describe 'authentication' do
    it 'never lets an unauthenticated request drive an order action' do
      allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!).and_call_original

      post "/api/v1/ifood/orders/#{order.id}/confirm", as: :json

      expect(response).not_to have_http_status(:ok)
    end
  end
end
