# frozen_string_literal: true

module GoogleAdsAssetSerializer
  extend self

  def serialize(asset)
    {
      id: asset.id,
      kind: asset.kind,
      name: asset.name,
      payload: asset.payload,
      published_at: asset.published_at,
      google_resource_names: asset.google_resource_names,
      created_at: asset.created_at,
      updated_at: asset.updated_at
    }
  end
end
