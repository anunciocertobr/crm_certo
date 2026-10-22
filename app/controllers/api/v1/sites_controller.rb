# frozen_string_literal: true

# CRUD de Sites (Dashboards > Sites) — autenticado, sem gate de permissão
# própria (mesmo padrão da página Dashboard hoje, que também não usa
# require_permissions/PermissionRoute).
class Api::V1::SitesController < Api::V1::BaseController
  before_action :fetch_site, only: %i[show update destroy leads webhook_info regenerate_webhook_token]

  def index
    sites = Site.order(created_at: :desc)
    counts = SiteLeadSubmission.where(site_id: sites.map(&:id)).group(:site_id).count

    success_response(
      data: sites.map { |site| SiteSerializer.serialize(site, leads_count: counts[site.id] || 0) },
      message: 'Sites retrieved successfully'
    )
  end

  def show
    success_response(
      data: SiteSerializer.serialize(@site, leads_count: @site.site_lead_submissions.count),
      message: 'Site retrieved successfully'
    )
  end

  def create
    @site = Site.new(site_params)
    @site.name = Sites::TitleFetcherService.call(@site.url) if @site.url.present? && site_params[:name].blank?

    if @site.save
      success_response(data: SiteSerializer.serialize(@site, leads_count: 0), message: 'Site created successfully', status: :created)
    else
      validation_error(@site)
    end
  end

  # `refetch_title: true` reprocessa o <title> — fora isso, um `name`
  # editado à mão nunca é sobrescrito silenciosamente.
  def update
    @site.assign_attributes(site_params)
    @site.name = Sites::TitleFetcherService.call(@site.url) if ActiveModel::Type::Boolean.new.cast(params[:refetch_title])

    if @site.save
      success_response(data: SiteSerializer.serialize(@site, leads_count: @site.site_lead_submissions.count), message: 'Site updated successfully')
    else
      validation_error(@site)
    end
  end

  def destroy
    @site.destroy
    success_response(data: { id: @site.id }, message: 'Site deleted successfully')
  end

  def leads
    rows = @site.site_lead_submissions.order(created_at: :desc).limit(500)
    success_response(
      data: rows.map { |row| SiteLeadSubmissionSerializer.serialize(row) },
      message: 'Leads retrieved successfully'
    )
  end

  def webhook_info
    success_response(data: webhook_info_payload, message: 'Webhook info retrieved successfully')
  end

  def regenerate_webhook_token
    @site.regenerate_webhook_token
    success_response(data: webhook_info_payload, message: 'Webhook token regenerated successfully')
  end

  private

  def webhook_info_payload
    backend_url = ENV['BACKEND_URL'].to_s.strip.presence || request.base_url
    {
      webhook_url: "#{backend_url}/api/v1/webhooks/sites/#{@site.webhook_token}",
      leads_count: @site.site_lead_submissions.count
    }
  end

  def fetch_site
    @site = Site.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Site not found', status: :not_found)
  end

  def site_params
    params.permit(:url, :name, :active)
  end

  def validation_error(record)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      record.errors.full_messages.join(', '),
      details: record.errors.as_json,
      status: :unprocessable_entity
    )
  end
end
