#============================================================================
# Файл: app/mailers/task_automation_mailer.rb
# Назначение: Класс для отправки email уведомлений об ошибках автоматизации задач
#============================================================================
class TaskAutomationMailer < ActionMailer::Base
  layout 'mailer'
  
  def error_notification(recipient_email, subject, body)
    Rails.logger.info "[TaskAutomation] [MAILER] >>> ВХОД В error_notification"
    Rails.logger.info "[TaskAutomation] [MAILER] recipient_email: #{recipient_email}"
    Rails.logger.info "[TaskAutomation] [MAILER] subject: #{subject}"
    Rails.logger.info "[TaskAutomation] [MAILER] body (первые 50 символов): #{body[0..50]}..."
    
    @body = body
    @subject = subject
    
    Rails.logger.info "[TaskAutomation] [MAILER] Вызов mail()..."
    
    mail_obj = mail(
      to: recipient_email,
      subject: subject,
      body: body,
      content_type: 'text/plain; charset=UTF-8'
    )
    
    Rails.logger.info "[TaskAutomation] [MAILER] mail() вернул объект: #{mail_obj.class}"
    Rails.logger.info "[TaskAutomation] [MAILER] mail_obj.to: #{mail_obj.to.inspect}"
    Rails.logger.info "[TaskAutomation] [MAILER] mail_obj.subject: #{mail_obj.subject}"
    Rails.logger.info "[TaskAutomation] [MAILER] <<< ВЫХОД ИЗ error_notification"
    
    mail_obj
  end
end