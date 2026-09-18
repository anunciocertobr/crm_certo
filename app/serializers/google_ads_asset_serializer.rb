# frozen_string_literal: true

module GoogleAdsAssetSerializer
  extend self

  def serialize(asset)
    {
      id: asset.id,
      kind: asset.kind,
      name: asset.name,
      payload: asset.payload,
      created_at: asset.created_at,
      updated_at: asset.updated_at
    }
  end
end
