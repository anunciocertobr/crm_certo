module GestorPosts
  # Upload de vídeo pro TikTok é lento (3 chamadas + PUT do binário
  # inteiro), então roda em background — ver Tiktok::UploadService.
  class TiktokUploadJob < ApplicationJob
    queue_as :default

    def perform(tiktok_upload_id)
      upload = TiktokUpload.find_by(id: tiktok_upload_id)
      return unless upload

      upload.mark_uploading!

      begin
        Tiktok::UploadService.new(upload: upload).publish!
      rescue Tiktok::UploadService::Error => e
        Rails.logger.error("GestorPosts::TiktokUploadJob: #{e.message}")
        upload.mark_failed!(e.message)
      end
    end
  end
end
