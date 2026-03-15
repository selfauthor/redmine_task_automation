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
      processor = TaskAutomation::TaskProcessor.new
      result = processor.process
      
      # Отправляем только ошибки и предупреждения текущего запуска
      send_notifications(processor.collected_errors_and_warnings) if processor.has_errors_or_warnings?
      
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
        subtask_tracker_id: settings['subtask_tracker_id'].to_i
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
        FIELD_END_ON_WORKING_DAY => 'int',
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
        FIELD_END_ON_WORKING_DAY => 'int',
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
        FIELD_DURATION_DAYS => 'int'
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
    # Метод отправки уведомлений об ошибках и предупреждениях на электронную почту
    # Отправляет только ошибки и предупреждения текущего запуска в хронологическом порядке
    # НЕ отправляет сообщения уровня info
    # ============================================================================
    def self.send_notifications(logs = nil)
      # Если логи переданы явно — используем их
      # Иначе читаем из лога (для обратной совместимости)
      if logs.present?
        # Используем переданные данные текущего запуска (только ошибки и предупреждения)
        log_messages = logs
      else
        # Читаем из лога (только ошибки и предупреждения, без info)
        log_messages = read_errors_and_warnings
      end
      
      # Если нет сообщений — не отправляем
      return if log_messages.empty?
      
      # Подсчитываем количество ошибок и предупреждений для темы
      error_count = log_messages.count { |m| m.include?('[ERROR]') }
      warning_count = log_messages.count { |m| m.include?('[WARNING]') }
      
      # Если нет ни ошибок, ни предупреждений — не отправляем
      return if error_count == 0 && warning_count == 0
      
      # Формируем тему письма
      subject_parts = []
      subject_parts << "#{error_count} ошибок" if error_count > 0
      subject_parts << "#{warning_count} предупреждений" if warning_count > 0
      
      subject = I18n.t('task_automation.email.notification_subject', 
                       details: subject_parts.join(', '),
                       date: Time.now.strftime('%Y-%m-%d %H:%M'))
      
      # Формируем тело письма — все сообщения в хронологическом порядке
      body = log_messages.join("\n")
      
      # Получаем всех активных администраторов
      admin_users = User.active.where(admin: true)
      
      return if admin_users.empty?
      
      success_count = 0
      error_count_send = 0
      
      admin_users.each do |admin|
        begin
          unless Setting.mail_from.present?
            log_message('error', I18n.t('task_automation.log.email_not_configured'))
            error_count_send += 1 
            next
          end
          
          # Отправляем письмо объекту пользователя (не строке с email!)
          TaskAutomationMailer.notification(admin, subject, body).deliver_now
          success_count += 1
          
          log_message('info', I18n.t('task_automation.log.email_sent_to_admin', 
                                     admin: admin.login, 
                                     email: admin.mail))
        rescue => e
          error_count_send += 1
          log_message('error', I18n.t('task_automation.log.email_send_failed_to_admin', 
                                     admin: admin.login, 
                                     error: e.message))
        end
      end
      
      if success_count > 0
        log_message('info', I18n.t('task_automation.log.email_summary', 
                                   success: success_count, 
                                   errors: error_count_send))
      end
    end

    # ============================================================================
    # Метод чтения записей об ошибках и предупреждениях из журнала
    # Возвращает только записи [ERROR] и [WARNING] за сегодня в хронологическом порядке
    # НЕ возвращает сообщения уровня [INFO]
    # ============================================================================
    def self.read_errors_and_warnings
      return [] unless File.exist?(LOG_FILE_PATH)
      
      logs = []
      today = Date.today.strftime('%Y-%m-%d')
      
      File.foreach(LOG_FILE_PATH) do |line|
        # Проверяем, что строка начинается с сегодняшней даты
        if line.start_with?("[#{today} ")
          # Проверяем наличие [ERROR] или [WARNING] (но не [INFO])
          if (line.include?('[ERROR]') || line.include?('[WARNING]')) && !line.include?('[INFO]')
            logs << line.strip
          end
        end
      end
      
      # Строки уже в хронологическом порядке (порядок записи в файл)
      logs
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
      # --- Логирование начала проверки ---
      Rails.logger.info "[TaskAutomation] Проверка назначения группы: group_name='#{group_name}', project_id=#{project_id}"
      
      # --- Шаг 1: Поиск группы ---
      group = Group.find_by(name: group_name)
      if group.nil?
        Rails.logger.warn "[TaskAutomation] Группа не найдена: name='#{group_name}'"
        return false
      end
      Rails.logger.debug "[TaskAutomation] Группа найдена: id=#{group.id}, name='#{group.name}'"
      
      # --- Шаг 2: Поиск проекта ---
      project = Project.find_by(id: project_id)
      if project.nil?
        Rails.logger.warn "[TaskAutomation] Проект не найден: id=#{project_id}"
        return false
      end
      Rails.logger.debug "[TaskAutomation] Проект найден: id=#{project.id}, identifier='#{project.identifier}'"
      
      # --- Шаг 3: Поиск связи проекта и группы (Member) ---
      member = Member.find_by(project: project, principal: group)
      if member.nil?
        Rails.logger.warn "[TaskAutomation] Группа не является участником проекта: group_id=#{group.id}, project_id=#{project_id}"
        return false
      end
      Rails.logger.debug "[TaskAutomation] Связь найдена: member_id=#{member.id}"
      
      # --- Шаг 4: Проверка ролей и прав ---
      has_permission = member.roles.any? { |role| role.permissions.include?(:edit_issues) }
      
      if has_permission
        Rails.logger.info "[TaskAutomation] Проверка пройдена: группа '#{group_name}' имеет право edit_issues в проекте #{project_id}"
      else
        Rails.logger.warn "[TaskAutomation] Проверка не пройдена: у группы '#{group_name}' нет права edit_issues в проекте #{project_id}"
        Rails.logger.debug "[TaskAutomation] Роли группы в проекте: #{member.roles.map { |r| "#{r.name}(#{r.id})" }.join(', ')}"
      end
      
      return has_permission
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
      
      # ✅ ИСПРАВЛЕНО: Правильное название настройки Redmine
      # non_working_week_days хранит выходные дни: ['6', '7'] (сб, вс)
      non_working_days = Setting['non_working_week_days'] || ['6', '7']
      
      # Преобразуем в массив целых чисел
      non_working_days = non_working_days.map(&:to_i) if non_working_days.is_a?(Array)
      
      # ✅ Преобразуем wday в формат Redmine:
      # Ruby: 0=вс, 1=пн, 2=вт, 3=ср, 4=чт, 5=пт, 6=сб
      # Redmine: 1=пн, 2=вт, 3=ср, 4=чт, 5=пт, 6=сб, 7=вс
      redmine_wday = wday == 0 ? 7 : wday
      
      # ✅ День рабочий, если он НЕ в списке выходных
      !non_working_days.include?(redmine_wday)
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