# frozen_string_literal: true

# CourseSerializer - curso no card da vitrine e na listagem do criador.
#
# Nao inclui a lista de aulas: a vitrine carrega dezenas de curso por linha e
# nenhuma delas precisa das aulas. Quem abre o curso usa CourseDetailSerializer.
module CourseSerializer
  extend self

  def serialize(course, viewer: nil)
    base_payload(course).merge(creator: creator_summary(course), viewer: viewer_state(course, viewer))
  end

  def serialize_collection(courses, viewer: nil)
    return [] unless courses

    courses.map { |course| serialize(course, viewer: viewer) }
  end

  def base_payload(course)
    {
      id: course.id,
      slug: course.slug,
      title: course.title,
      subtitle: course.subtitle,
      description: course.description,
      category: course.category,
      level: course.level,
      status: course.status,
      created_at: course.created_at&.iso8601,
      updated_at: course.updated_at&.iso8601
    }.merge(media_payload(course), price_payload(course), stats_payload(course))
  end

  def media_payload(course)
    {
      thumbnail_url: course.thumbnail_url,
      trailer_provider: course.trailer_provider,
      trailer_video_id: course.trailer_video_id,
      trailer_embed_url: course.trailer_embed_url
    }
  end

  def price_payload(course)
    {
      price_cents: course.price_cents,
      price_formatted: course.price_formatted,
      currency: course.currency,
      free: course.free?,
      paid: course.paid?
    }
  end

  def stats_payload(course)
    {
      lessons_count: course.lessons_count,
      duration_seconds: course.duration_seconds,
      students_count: course.students_count,
      rating_average: course.rating_average.to_f,
      rating_count: course.rating_count
    }
  end

  private

  def creator_summary(course)
    creator = course.creator_profile
    return nil if creator.nil?

    {
      id: creator.id,
      slug: creator.slug,
      display_name: creator.public_name,
      avatar_url: creator.avatar_url
    }
  end

  # O que o card precisa saber sobre AQUELE aluno: se esta na lista de desejo,
  # se ja esta inscrito (e quanto andou) e se ja pediu a compra. Sem isso, a
  # vitrine faria uma consulta por card so para desenhar o coracao.
  def viewer_state(course, viewer)
    return empty_viewer_state if viewer.nil?

    enrollment = CourseEnrollment.find_by(course_id: course.id, user_id: viewer.id)

    {
      enrolled: enrollment.present?,
      progress_percent: enrollment&.progress_percent.to_f,
      wishlisted: CourseWishlist.exists?(course_id: course.id, user_id: viewer.id),
      purchase_pending: CoursePurchaseRequest.pending.exists?(course_id: course.id, user_id: viewer.id)
    }
  end

  def empty_viewer_state
    { enrolled: false, progress_percent: 0.0, wishlisted: false, purchase_pending: false }
  end
end