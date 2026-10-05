# frozen_string_literal: true

# CreatorProfileSerializer - perfil do vendedor de curso.
#
# `mine` e o que a propria area do criador precisa ver (inclusive o que ainda
# nao foi publicado). O publico nunca recebe o rascunho.
module CreatorProfileSerializer
  extend self

  def serialize(profile, viewer: nil, mine: false)
    {
      id: profile.id,
      slug: profile.slug,
      display_name: profile.public_name,
      headline: profile.headline,
      bio: profile.bio,
      avatar_url: profile.avatar_url,
      banner_url: profile.banner_url,
      whatsapp: profile.whatsapp,
      pix_key: mine ? profile.pix_key : nil,
      published: profile.is_published,
      published_at: profile.published_at&.iso8601,
      courses_count: profile.courses_count,
      followers_count: profile.followers_count,
      students_count: profile.students_count,
      followed_by_me: profile.followed_by?(viewer),
      created_at: profile.created_at&.iso8601,
      updated_at: profile.updated_at&.iso8601
    }
  end

  def serialize_collection(profiles, viewer: nil)
    return [] unless profiles

    profiles.map { |profile| serialize(profile, viewer: viewer) }
  end
end
