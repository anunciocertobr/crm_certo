# frozen_string_literal: true

# CourseDetailSerializer - curso aberto: modulos, aulas e o que o aluno pode
# assistir de cada uma (preview ou nao).
#
# A distincao `locked` vem do servidor, nao do cliente: a tela usa para mostrar
# cadeado, e um aluno curioso nao deve conseguir montar o embed na mao.
module CourseDetailSerializer
  extend self

  def serialize(course, viewer: nil, enrollment: nil)
    enrollment ||= viewer && CourseEnrollment.find_by(course_id: course.id, user_id: viewer.id)

    CourseSerializer.serialize(course, viewer: viewer).merge(
      creator: creator_payload(course, viewer),
      modules: modules(course, enrollment),
      enrollment: enrollment_payload(enrollment),
      enrolled: enrollment.present?
    )
  end

  def modules(course, enrollment)
    enrolled = enrollment.present?

    course.course_modules.map do |mod|
      {
        id: mod.id,
        title: mod.title,
        position: mod.position,
        duration_seconds: mod.duration_seconds,
        lessons: mod.course_lessons.map { |lesson| lesson_payload(lesson, enrolled) }
      }
    end
  end

  private

  def creator_payload(course, viewer)
    creator = course.creator_profile
    return nil if creator.nil?

    CreatorProfileSerializer.serialize(creator, viewer: viewer, mine: false).merge(
      headline: creator.headline,
      bio: creator.bio,
      banner_url: creator.banner_url,
      whatsapp: creator.whatsapp,
      pix_key: creator.pix_key,
      published_at: creator.published_at&.iso8601
    )
  end

  def enrollment_payload(enrollment)
    return nil if enrollment.nil?

    {
      id: enrollment.id,
      status: enrollment.status,
      source: enrollment.source,
      progress_percent: enrollment.progress_percent,
      last_lesson_id: enrollment.last_lesson_id,
      started_at: enrollment.started_at&.iso8601,
      last_watched_at: enrollment.last_watched_at&.iso8601
    }
  end

  def lesson_payload(lesson, enrolled)
    unlocked = enrolled || lesson.is_preview

    {
      id: lesson.id,
      title: lesson.title,
      description: lesson.description,
      position: lesson.position,
      duration_seconds: lesson.duration_seconds,
      video_provider: lesson.video_provider,
      is_preview: lesson.is_preview,
      locked: !unlocked,
      # Embed so quando destravado: preview liberou, bloco pago nao.
      embed_url: unlocked ? lesson.embed_url : nil
    }
  end
end