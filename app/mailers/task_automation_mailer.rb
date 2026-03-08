#============================================================================
# Файл: app/mailers/task_automation_mailer.rb
# Назначение: Класс для отправки email уведомлений об ошибках автоматизации задач
#============================================================================
class TaskAutomationMailer < Mailer
  # Наследуемся от стандартного Mailer Redmine для использования всех системных настроек почты
  
  def error_notification(user, subject, body)
    @user = user
    @body = body
    @subject = subject
  
    # Явно указываем только текстовый формат
    mail(
      to: user,
      subject: subject
    ) do |format|
      format.text
      # format.html — закомментировано, HTML-версия не генерируется
    end
  end
end