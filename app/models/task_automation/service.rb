# ============================================================================
# Файл: app/models/task_automation/service.rb
# Назначение: Сервисный класс для доступа к функционалу автоматизации задач
# ============================================================================

module TaskAutomation
  class Service
    # Явно включаем модуль конфигурации
    include TaskAutomation::Configuration
    # ============================================================================
    # Константы
    # ============================================================================
    LOG_FILE_PATH = Rails.root.join('log', 'task_automation.log').to_s
    LOG_MAX_SIZE = 10 * 1024 * 1024
    
    # ============================================================================
    # Основной метод запуска обработки задач
    # ============================================================================
    def self.process
      # Создание нового экземпляра процессора для обработки
      processor = TaskAutomation::TaskProcessor.new
      
      # Запуск процесса обработки и получение результатов
      result = processor.process
      
      # Отправка уведомлений об ошибках, если они были зафиксированы
      send_error_notifications if processor.has_errors?
      
      # Возврат структурированного результата выполнения
      result
    end
    
    # ============================================================================
    # Метод получения настроек плагина из таблицы settings
    # ============================================================================
    def self.get_settings
      # Получение всех настроек плагина через стандартный механизм Redmine
      settings = Setting.plugin_redmine_task_automation
      
      # Возврат настроек с значениями по умолчанию для отсутствующих ключей
      {
        source_project_id: settings['source_project_id'].to_i,
        author_id: settings['author_id'].to_i,
        tracker_id: settings['tracker_id'].to_i,
        error_notification_email: settings['error_notification_email']
      }
    end
    
    # ============================================================================
    # Метод получения ID кастомного поля по его названию
    # ============================================================================
    def self.get_custom_field_id_by_name(field_name)
      # Поиск кастомного поля в базе данных по имени (нечувствительно к регистру)
      custom_field = CustomField.find_by(name: field_name, field_format: 'string')
      
      # Если не найдено как строка, пробуем другие форматы
      custom_field ||= CustomField.find_by(name: field_name)
      
      # Возврат ID поля или nil, если поле не найдено
      custom_field&.id
    end
    
    # ============================================================================
    # Метод получения всех кастомных полей плагина с их ID
    # ============================================================================
    def self.get_all_custom_fields_with_ids
      fields_with_ids = {}
      
      TaskAutomation::Configuration::REQUIRED_CUSTOM_FIELDS.each do |field_name|
        fields_with_ids[field_name] = get_custom_field_id_by_name(field_name)
      end
      
      fields_with_ids
    end
    
    # ============================================================================
    # Метод проверки наличия всех необходимых кастомных полей
    # ============================================================================
    def self.check_missing_custom_fields
      missing_fields = []
      
      TaskAutomation::Configuration::REQUIRED_CUSTOM_FIELDS.each do |field_name|
        field_id = get_custom_field_id_by_name(field_name)
        missing_fields << field_name unless field_id.present?
      end
      
      missing_fields
    end
    
    # ============================================================================
    # Метод записи сообщения в журнал логирования
    # ============================================================================
    def self.log_message(level, message, issue_id = nil)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      
      log_entry = "[#{timestamp}] [#{level.upcase}]"
      log_entry += " [Issue ##{issue_id}]" if issue_id
      log_entry += " #{message}"
      
      rotate_log_file if File.exist?(LOG_FILE_PATH) && File.size(LOG_FILE_PATH) > LOG_MAX_SIZE
      
      log_dir = File.dirname(LOG_FILE_PATH)
      FileUtils.mkdir_p(log_dir) unless File.directory?(log_dir)
      
      File.open(LOG_FILE_PATH, 'a') { |f| f.puts(log_entry) }
    end
    
    # ============================================================================
    # Метод ротации файла журнала
    # ============================================================================
    def self.rotate_log_file
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      rotated_file = "#{LOG_FILE_PATH}.#{timestamp}"
      
      File.rename(LOG_FILE_PATH, rotated_file) if File.exist?(LOG_FILE_PATH)
    end
    
    # ============================================================================
    # Метод отправки уведомлений об ошибках на электронную почту
    # ============================================================================
    def self.send_error_notifications
      email = get_settings[:error_notification_email]
      
      return if email.blank?
      
      error_messages = read_error_logs
      
      return if error_messages.empty?
      
      subject = I18n.t('task_automation.email.error_subject', 
                       count: error_messages.count,
                       date: Time.now.strftime('%Y-%m-%d %H:%M'))
      
      body = I18n.t('task_automation.email.error_body', 
                    errors: error_messages.join("\n"))
      
      begin
        Mailer.deliver_now(
          to: email,
          subject: subject,
          body: body
        )
      rescue => e
        log_message('error', I18n.t('task_automation.log.email_send_failed', error: e.message))
      end
    end
    
    # ============================================================================
    # Метод чтения записей об ошибках из журнала
    # ============================================================================
    def self.read_error_logs
      return [] unless File.exist?(LOG_FILE_PATH)
      
      errors = []
      today = Date.today.strftime('%Y-%m-%d')
      
      File.foreach(LOG_FILE_PATH) do |line|
        if line.include?('[ERROR]') && line.start_with?("[#{today}")
          error_message = line.split('[ERROR]').last&.strip
          errors << error_message if error_message.present?
        end
      end
      
      errors
    end
    
    # ============================================================================
    # Метод проверки существования проекта по ID
    # ============================================================================
    def self.project_exists?(project_id)
      Project.exists?(project_id)
    end
    
    # ============================================================================
    # Метод проверки существования трекера в проекте
    # ============================================================================
    def self.tracker_exists_in_project?(project_id, tracker_id)
      project = Project.find_by(id: project_id)
      return false unless project
      
      project.trackers.exists?(tracker_id)
    end
    
    # ============================================================================
    # Метод проверки существования группы пользователей
    # ============================================================================
    def self.group_exists?(group_name)
      Group.exists?(name: group_name)
    end
    
    # ============================================================================
    # Метод проверки, можно ли группе назначать задачи в проекте
    # ============================================================================
    def self.group_can_be_assigned?(group_name, project_id)
      group = Group.find_by(name: group_name)
      return false unless group
      
      project = Project.find_by(id: project_id)
      return false unless project
      
      member = Member.find_by(project: project, principal: group)
      return false unless member
      
      member.roles.any? { |role| role.permissions.include?(:edit_issues) }
    end
    
    # ============================================================================
    # Метод получения группы по имени
    # ============================================================================
    def self.get_group_by_name(group_name)
      Group.find_by(name: group_name)
    end
    
    # ============================================================================
    # Метод проверки, является ли день рабочим
    # ============================================================================
    def self.working_day?(date)
      wday = date.wday
      working_days = Setting.working_days || [1, 2, 3, 4, 5]
      working_days.include?(wday)
    end
    
    # ============================================================================
    # Метод сдвига даты на рабочие дни
    # ============================================================================
    def self.shift_to_working_day(date, direction: :forward)
      result_date = date.clone
      
      while !working_day?(result_date)
        if direction == :forward
          result_date += 1.day
        else
          result_date -= 1.day
        end
      end
      
      result_date
    end
  end
end