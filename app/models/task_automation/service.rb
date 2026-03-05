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
      
      # Возврат настроек со значениями по умолчанию для отсутствующих ключей
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
    # Метод проверки доступности трекера в проекте
    # ============================================================================
    def self.tracker_available_in_project?(project_id, tracker_id)
      return false unless project_id.present? && tracker_id.present?
      
      project = Project.find_by(id: project_id)
      return false unless project
      
      tracker = Tracker.find_by(id: tracker_id)
      return false unless tracker
      
      project.trackers.include?(tracker)
    end

    # ============================================================================
    # Метод проверки типа кастомного поля
    # ============================================================================
    def self.check_custom_field_types
      invalid_fields = []
      
      # Ожидаемые типы полей
      field_type_mapping = {
        FIELD_NEXT_EXECUTION_DATE => 'date',
        FIELD_CREATE_AHEAD_DAYS => 'int',
        FIELD_TARGET_PROJECT => 'string',
        FIELD_TARGET_TRACKER => 'string',
        FIELD_ASSIGNMENT_GROUP => 'string',
        FIELD_WATCHER_GROUPS => 'string',
        FIELD_DURATION_DAYS => 'int',
        FIELD_WORKING_DAYS_ONLY => 'int',
        FIELD_INTERVAL_UNIT => 'string',
        FIELD_INTERVAL_VALUE => 'int',
        FIELD_DAY_NUMBER => 'int',
        FIELD_REPEAT_DAYS => 'string',
        FIELD_MONTH => 'string',
        FIELD_SUBTASK_ORDER => 'int'
      }
      
      field_type_mapping.each do |field_name, expected_type|
        custom_field = CustomField.find_by(name: field_name)
        
        if custom_field
          # Нормализация типов для сравнения
          actual_type = custom_field.field_format
          type_match = case expected_type
                       when 'date'
                         actual_type == 'date'
                       when 'int'
                         ['int', 'float'].include?(actual_type)
                       when 'string'
                         ['string', 'text', 'list'].include?(actual_type)
                       else
                         actual_type == expected_type
                       end
          
          unless type_match
            invalid_fields << {
              field: field_name,
              expected: expected_type,
              actual: actual_type
            }
          end
        end
      end
      
      invalid_fields
    end

    # ============================================================================
    # Метод проверки доступности полей для трекера
    # ============================================================================
    def self.check_fields_available_for_tracker(tracker_id)
      unavailable_fields = []
      
      return unavailable_fields unless tracker_id.present?
      
      tracker = Tracker.find_by(id: tracker_id)
      return unavailable_fields unless tracker
      
      TaskAutomation::Configuration::REQUIRED_CUSTOM_FIELDS.each do |field_name|
        custom_field = CustomField.find_by(name: field_name)
        
        if custom_field
          unless tracker.custom_fields.include?(custom_field)
            unavailable_fields << field_name
          end
        end
      end
      
      unavailable_fields
    end

    # ==========================================================================
    # НОВЫЙ МЕТОД: Проверка полей для трекера основных задач
    # ==========================================================================
    def self.check_main_task_fields(tracker_id)
      unavailable_fields = []
      
      return unavailable_fields unless tracker_id.present?
      
      tracker = Tracker.find_by(id: tracker_id)
      return unavailable_fields unless tracker
      
      TaskAutomation::Configuration::MAIN_TASK_FIELDS.each do |field_name|
        custom_field = CustomField.find_by(name: field_name)
        
        if custom_field
          unless tracker.custom_fields.include?(custom_field)
            unavailable_fields << field_name
          end
        end
      end
      
      unavailable_fields
    end

    # ==========================================================================
    # НОВЫЙ МЕТОД: Проверка полей для трекера подзадач
    # ==========================================================================
    def self.check_subtask_fields(tracker_id)
      unavailable_fields = []
      
      return unavailable_fields unless tracker_id.present?
      
      tracker = Tracker.find_by(id: tracker_id)
      return unavailable_fields unless tracker
      
      TaskAutomation::Configuration::SUBTASK_FIELDS.each do |field_name|
        custom_field = CustomField.find_by(name: field_name)
        
        if custom_field
          unless tracker.custom_fields.include?(custom_field)
            unavailable_fields << field_name
          end
        end
      end
      
      unavailable_fields
    end

    # ==========================================================================
    # НОВЫЙ МЕТОД: Проверка типов полей для основных задач
    # ==========================================================================
    def self.check_main_task_field_types
      invalid_fields = []
      
      field_type_mapping = {
        FIELD_NEXT_EXECUTION_DATE => 'date',
        FIELD_CREATE_AHEAD_DAYS => 'int',
        FIELD_TARGET_PROJECT => 'string',
        FIELD_TARGET_TRACKER => 'string',
        FIELD_ASSIGNMENT_GROUP => 'string',
        FIELD_WATCHER_GROUPS => 'string',
        FIELD_DURATION_DAYS => 'int',
        FIELD_WORKING_DAYS_ONLY => 'int',
        FIELD_INTERVAL_UNIT => 'string',
        FIELD_INTERVAL_VALUE => 'int',
        FIELD_DAY_NUMBER => 'int',
        FIELD_REPEAT_DAYS => 'string',
        FIELD_MONTH => 'string'
      }
      
      field_type_mapping.each do |field_name, expected_type|
        custom_field = CustomField.find_by(name: field_name)
        
        if custom_field
          actual_type = custom_field.field_format
          type_match = case expected_type
                       when 'date'
                         actual_type == 'date'
                       when 'int'
                         ['int', 'float'].include?(actual_type)
                       when 'string'
                         ['string', 'text', 'list'].include?(actual_type)
                       else
                         actual_type == expected_type
                       end
          
          unless type_match
            invalid_fields << {
              field: field_name,
              expected: expected_type,
              actual: actual_type
            }
          end
        end
      end
      
      invalid_fields
    end
    
    # ==========================================================================
    # НОВЫЙ МЕТОД: Проверка типов полей для подзадач
    # ==========================================================================
    def self.check_subtask_field_types
      invalid_fields = []
      
      field_type_mapping = {
        FIELD_PARENT_ISSUE => 'int',
        FIELD_TARGET_TRACKER => 'string',
        FIELD_ASSIGNMENT_GROUP => 'string',
        FIELD_SUBTASK_ORDER => 'int',
        FIELD_DURATION_DAYS => 'int',
        FIELD_WORKING_DAYS_ONLY => 'int'
      }
      
      field_type_mapping.each do |field_name, expected_type|
        custom_field = CustomField.find_by(name: field_name)
        
        if custom_field
          actual_type = custom_field.field_format
          type_match = case expected_type
                       when 'date'
                         actual_type == 'date'
                       when 'int'
                         ['int', 'float'].include?(actual_type)
                       when 'string'
                         ['string', 'text', 'list'].include?(actual_type)
                       else
                         actual_type == expected_type
                       end
          
          unless type_match
            invalid_fields << {
              field: field_name,
              expected: expected_type,
              actual: actual_type
            }
          end
        end
      end
      
      invalid_fields
    end
    
    # ==========================================================================
    # ОБНОВЛЁННЫЙ МЕТОД: Проверка соответствия трекера подзадач
    # ==========================================================================
    def self.validate_subtask_tracker(subtask, expected_tracker_id)
      return true unless expected_tracker_id.present?
      
      expected_tracker = Tracker.find_by(id: expected_tracker_id)
      return false unless expected_tracker
      
      subtask.tracker_id == expected_tracker_id
    end

    # ===========================================================
    # Проверка прав пользователя на чтение и редактирование задач
    # ===========================================================
    def self.check_author_permissions(author_id, project_id)
      issues = []
      
      return issues unless author_id.present? && project_id.present?
      
      author = User.find_by(id: author_id)
      return [{ type: 'error', message: 'Пользователь не найден' }] unless author
      
      project = Project.find_by(id: project_id)
      return [{ type: 'error', message: 'Проект не найден' }] unless project
      
      # Проверка через роль и разрешения
      member = Member.find_by(project: project, principal: author)
      
      unless member
        # Проверяем через группы пользователя
        has_view_permission = false
        has_edit_permission = false
        
        author.groups.each do |group|
          group_member = Member.find_by(project: project, principal: group)
          if group_member
            group_permissions = group_member.roles.flat_map(&:permissions)
            has_view_permission = true if group_permissions.include?(:view_issues)
            has_edit_permission = true if group_permissions.include?(:edit_issues)
          end
        end
        
        unless has_view_permission
          issues << {
            type: 'error',
            message: "Пользователь #{author.login} не имеет права 'view_issues' в проекте #{project.name}"
          }
        end
        
        unless has_edit_permission
          issues << {
            type: 'error',
            message: "Пользователь #{author.login} не имеет права 'edit_issues' в проекте #{project.name}"
          }
        end
      else
        permissions = member.roles.flat_map(&:permissions)
        
        unless permissions.include?(:view_issues)
          issues << {
            type: 'error',
            message: "Пользователь #{author.login} не имеет права 'view_issues' в проекте #{project.name}"
          }
        end
        
        unless permissions.include?(:edit_issues)
          issues << {
            type: 'error',
            message: "Пользователь #{author.login} не имеет права 'edit_issues' в проекте #{project.name}"
          }
        end
      end
      
      # Проверка наличия кастомного поля "Дата следующего выполнения"
      next_execution_field = CustomField.find_by(name: FIELD_NEXT_EXECUTION_DATE)
      if next_execution_field
        issues << {
          type: 'success',
          message: "Кастомное поле '#{FIELD_NEXT_EXECUTION_DATE}' найдено в системе"
        }
      else
        issues << {
          type: 'warning',
          message: "Кастомное поле '#{FIELD_NEXT_EXECUTION_DATE}' не найдено в системе"
        }
      end

      issues
    end

    # ============================================================================
    # Метод записи результатов тестирования в журнал
    # ============================================================================
    def self.log_test_results(test_results)
      log_message('info', '=== НАЧАЛО ТЕСТИРОВАНИЯ НАСТРОЕК ===')
      
      test_results.each do |result|
        level = case result[:status]
                when 'success' then 'info'
                when 'warning' then 'warning'
                when 'error' then 'error'
                else 'info'
                end
        
        log_message(level, "[ТЕСТ] #{result[:status].upcase}: #{result[:message]}")
      end
      
      log_message('info', '=== ЗАВЕРШЕНИЕ ТЕСТИРОВАНИЯ НАСТРОЕК ===')
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