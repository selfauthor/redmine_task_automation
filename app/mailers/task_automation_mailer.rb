#============================================================================
# Файл: app/mailers/task_automation_mailer.rb
# Назначение: Класс для отправки email уведомлений об ошибках автоматизации задач
#============================================================================
class TaskAutomationMailer < Mailer
  # Метод отправки уведомления (ошибки + предупреждения)
  def notification(admin, subject, body)
    @admin = admin
    @body = body
    @subject = subject
    
    mail(
      to: admin.mail,
      from: Setting.mail_from,
      subject: @subject
    ) do |format|
      format.text
    end
  end
end