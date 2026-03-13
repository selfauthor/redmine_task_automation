#============================================================================
# Файл: lib/task_automation/task_processor.rb
# Назначение: Основной процессор бизнес-логики для автоматизации задач
#============================================================================

module TaskAutomation
  class TaskProcessor
    # Явно включаем модуль конфигурации для доступа к константам
    include TaskAutomation::Configuration

    # ============================================================================
    # Инициализация процессора
    # ============================================================================
    def initialize
      @errors = []
      @warnings = []
      @messages = []
      @created_issues_count = 0
      @created_subtasks_count = 0
      @settings = TaskAutomation::Service.get_settings
      @custom_field_ids = {}
      
      initialize_custom_field_cache
    end

    # ============================================================================
    # Метод добавления предупреждения с полной информацией для логирования
    # Формат: [2026-03-08 15:18:33] [WARNING] [Issue #1] Текст предупреждения
    # ============================================================================
    def add_warning(message, issue_id = nil)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      log_entry = "[#{timestamp}] [WARNING] "
      log_entry += "[Issue ##{issue_id}] " if issue_id
      log_entry += "#{message} "
      
      @warnings << log_entry
      
      # Также логируем в файл
      TaskAutomation::Service.log_message('warning', message, issue_id)
    end

    # ============================================================================
    # Метод добавления ошибки с полной информацией для логирования и отправки
    # Формат: [2026-03-08 15:18:33] [ERROR] [Issue #1] Текст ошибки
    # ============================================================================
    def add_error(message, issue_id = nil)
      timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      log_entry = "[#{timestamp}] [ERROR] "
      log_entry += "[Issue ##{issue_id}] " if issue_id
      log_entry += "#{message} "
      
      @errors << log_entry
      
      # Также логируем в файл (без дублирования префикса времени)
      TaskAutomation::Service.log_message('error', message, issue_id)
    end

    # ============================================================================
    # Основной метод обработки всех задач-шаблонов
    # ============================================================================
    def process
      TaskAutomation::Service.log_message('info', I18n.t('task_automation.log.processing_started'))
      
      unless validate_settings
        TaskAutomation::Service.log_message('error', I18n.t('task_automation.log.settings_invalid'))
        return build_result(false)
      end
      
      template_issues = find_template_issues
      
      if template_issues.empty?
        TaskAutomation::Service.log_message('info', I18n.t('task_automation.log.no_templates_found'))
        return build_result(true)
      end
      
      template_issues.each do |template_issue|
        begin
          process_template_issue(template_issue)
        rescue => e
          add_error(I18n.t('task_automation.log.template_processing_error', 
                         issue_id: template_issue.id, 
                         error: e.message), template_issue.id)
        end
      end
      
      log_summary
      build_result(@errors.empty?)
    end

    # ============================================================================
    # Метод проверки валидности настроек плагина
    # ============================================================================
    def validate_settings
      if @settings[:source_project_id].blank?
        @errors << I18n.t('task_automation.validation.source_project_required')
        return false
      end
      
      unless TaskAutomation::Service.project_exists?(@settings[:source_project_id])
        @errors << I18n.t('task_automation.validation.source_project_not_found')
        return false
      end
      
      if @settings[:author_id].blank?
        @errors << I18n.t('task_automation.validation.author_required')
        return false
      end
      
      unless User.exists?(@settings[:author_id])
        @errors << I18n.t('task_automation.validation.author_not_found')
        return false
      end
      
      if @settings[:tracker_id].blank?
        @errors << I18n.t('task_automation.validation.tracker_required')
        return false
      end
      
      true
    end

    # ============================================================================
    # Метод инициализации кэша ID кастомных полей
    # ============================================================================
    def initialize_custom_field_cache
      TaskAutomation::Configuration::REQUIRED_CUSTOM_FIELDS.each do |field_name|
        @custom_field_ids[field_name] = TaskAutomation::Service.get_custom_field_id_by_name(field_name)
      end
    end

    # ============================================================================
    # Метод поиска задач-шаблонов для обработки
    # ============================================================================
    def find_template_issues
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      
      if date_field_id.blank?
        @errors << I18n.t('task_automation.validation.date_field_not_found')
        return []
      end
      
      ahead_days_field_id = @custom_field_ids[FIELD_CREATE_AHEAD_DAYS]
      today = Date.today
      
      Issue.where(
        project_id: @settings[:source_project_id],
        tracker_id: @settings[:tracker_id]
      ).select do |issue|
        next_date = issue.custom_field_value(date_field_id)
        ahead_days = ahead_days_field_id.present? ? 
                     (issue.custom_field_value(ahead_days_field_id).to_i rescue 0) : 0
        
        next_date.present? && (next_date.to_date - ahead_days.days) <= today
      end
    end

    # ============================================================================
    # Метод обработки отдельной задачи-шаблона
    # ============================================================================
    def process_template_issue(template_issue)
      TaskAutomation::Service.log_message('info', 
        I18n.t('task_automation.log.processing_template', issue_id: template_issue.id),
        template_issue.id)
      
      target_issue = nil
      
      begin
        # Шаг 3.1: Проверка проекта назначения
        target_project = get_target_project(template_issue)
        return unless target_project
        
        # Шаг 3.2: Проверка трекера
        target_tracker = get_target_tracker(template_issue, target_project)
        return unless target_tracker
        
        # Шаг 3.3: Проверка назначения (пользователь или группа)
        assignee = get_assignee(template_issue)
        return unless assignee
        
        # Шаг 3.4: Создание целевой задачи
        target_issue = create_target_issue(template_issue, target_project, target_tracker, assignee)
        return unless target_issue
        
        Rails.logger.info "[TaskAutomation] process_template_issue: Задача создана - target_issue_id=#{target_issue.id}, lock_version=#{target_issue.lock_version}"
        
        # Шаг 3.5: Добавление наблюдателей (ПЕРЕД сохранением дат!)
        target_issue.reload
        
        # Добавление наблюдателей
        add_watchers(target_issue, template_issue, assignee)
        
        # Еще раз reload перед сохранением дат
        target_issue.reload
        Rails.logger.info "[TaskAutomation] process_template_issue: Наблюдатели добавлены"
        
        # Шаг 3.6: Перезагружаем задачу после добавления наблюдателей
        target_issue.reload
        Rails.logger.info "[TaskAutomation] process_template_issue: Задача перезажружена - lock_version=#{target_issue.lock_version}"
        
        # Шаг 3.7: Обработка подзадач
        has_subtasks = template_issue.children.any?
        
        if has_subtasks
          success, subtasks_count = process_subtasks(template_issue, target_issue, target_project, assignee)
          
          unless success
            target_issue.destroy
            add_error(I18n.t('task_automation.log.subtask_processing_failed'), template_issue.id)
            return
          end
          
          @created_subtasks_count += subtasks_count
          calculate_parent_due_date(target_issue, template_issue)
        else
          calculate_single_issue_dates(target_issue, template_issue)
        end
        
        # Шаг 3.8: Логирование успешного создания
        subtask_message = has_subtasks ? 
           I18n.t('task_automation.log.with_subtasks', count: target_issue.children.count) : ''
        
        TaskAutomation::Service.log_message('info',
          I18n.t('task_automation.log.issue_created', 
                 issue_id: target_issue.id,
                 subject: target_issue.subject,
                 subtasks: subtask_message),
          target_issue.id)
        
        @created_issues_count += 1

        # Отправка уведомлений наблюдателям и назначенному пользователю о создании задачи
        send_creation_notifications(target_issue, template_issue.id)
        
        # Шаг 3.9: Обновление даты следующего выполнения
        update_next_execution_date(template_issue)
        
        Rails.logger.info "[TaskAutomation] process_template_issue: УСПЕШНО завершено - target_issue_id=#{target_issue.id}"
        
      rescue => e
        Rails.logger.error "[TaskAutomation] process_template_issue: ОШИБКА - #{e.class}: #{e.message}"
        Rails.logger.error "[TaskAutomation] Backtrace: #{e.backtrace.first(5).join("\n")}"
        
        add_error(I18n.t('task_automation.log.template_processing_error', 
                       issue_id: template_issue.id, 
                       error: e.message), template_issue.id)
      end
    end

    # ============================================================================
    # Вспомогательные методы
    # ============================================================================
    def get_target_project(template_issue)
      project_field_id = @custom_field_ids[FIELD_TARGET_PROJECT]
      
      Rails.logger.debug "[TaskAutomation] get_target_project: FIELD_TARGET_PROJECT='#{FIELD_TARGET_PROJECT}'"
      Rails.logger.debug "[TaskAutomation] get_target_project: project_field_id=#{project_field_id}"
      
      unless project_field_id.present?
        add_error(I18n.t('task_automation.log.project_field_not_configured', field_name: FIELD_TARGET_PROJECT), template_issue.id)
        return nil
      end
      
      # Получаем ФРАГМЕНТ названия проекта из кастомного поля
      project_fragment = template_issue.custom_field_value(project_field_id)
      
      Rails.logger.debug "[TaskAutomation] get_target_project: project_fragment='#{project_fragment}' (class: #{project_fragment.class})"
      
      unless project_fragment.present?
        add_error(I18n.t('task_automation.log.project_field_empty', field_name: FIELD_TARGET_PROJECT), template_issue.id)
        return nil
      end
       
      # Ищем проект по фрагменту названия (первое совпадение)
      project = find_project_by_fragment(project_fragment.to_s.strip)
      
      Rails.logger.debug "[TaskAutomation] get_target_project: found project: #{project ? "id=#{project.id}, name='#{project.name}'" : 'nil'}"
      
      unless project
        add_error(I18n.t('task_automation.log.project_not_found', field_value: project_fragment), template_issue.id)
        return nil
      end
      
      # Дополнительная проверка: проект не должен быть архивирован
      if project.archived?
        Rails.logger.warn "[TaskAutomation] get_target_project: проект '#{project.name}' архивирован"
        add_error(I18n.t('task_automation.log.project_archived', project_name: project.name), template_issue.id)
        return nil
      end
      
      project
    end

    # ============================================================================
    # Поиск проекта по фрагменту названия
    # ============================================================================
    def find_project_by_fragment(fragment)
      return nil unless fragment.present?
      
      # Ищем среди активных проектов первое совпадение по фрагменту
      Project.active.each do |project|
        if project.name.downcase.include?(fragment.downcase)
          return project
        end
      end
      
      nil
    end

    def get_target_tracker(template_issue, target_project)
      tracker_field_id = @custom_field_ids[FIELD_TARGET_TRACKER]
      
      unless tracker_field_id.present?
        add_error(I18n.t('task_automation.log.tracker_field_not_configured', field_name: FIELD_TARGET_TRACKER), template_issue.id)
        return nil
      end
      
      tracker_name = template_issue.custom_field_value(tracker_field_id)
      
      unless tracker_name.present?
        add_error(I18n.t('task_automation.log.tracker_field_empty', field_name: FIELD_TARGET_TRACKER), template_issue.id)
        return nil
      end
      
      tracker = Tracker.find_by(name: tracker_name)
      
      unless tracker
        add_error(I18n.t('task_automation.log.tracker_not_found', tracker_name: tracker_name), template_issue.id)
        return nil
      end
      
      unless target_project.trackers.include?(tracker)
        add_error(I18n.t('task_automation.log.tracker_not_in_project', tracker_name: tracker_name, project_name: target_project.name), template_issue.id)
        return nil
      end
      
      tracker
    end

    def get_assignee(template_issue)
      assignee_field_id = @custom_field_ids[FIELD_ASSIGNMENT_GROUP]
      
      unless assignee_field_id.present?
        add_error(I18n.t('task_automation.log.assignee_field_not_configured', field_name: FIELD_ASSIGNMENT_GROUP), template_issue.id)
        return nil
      end
      
      # Получаем строку для поиска и очищаем от пробелов
      assignee_search_string = template_issue.custom_field_value(assignee_field_id)
      
      unless assignee_search_string.present?
        add_error(I18n.t('task_automation.log.assignee_field_empty', field_name: FIELD_ASSIGNMENT_GROUP), template_issue.id)
        return nil
      end
      
      # Очищаем от начальных и конечных пробелов
      assignee_search_string = assignee_search_string.to_s.strip 
      
      Rails.logger.debug "[TaskAutomation] get_assignee: search_string='#{assignee_search_string}'"
      
      # Ищем пользователя или группу по фрагменту имени
      assignee = find_user_or_group_by_name_fragment(assignee_search_string)
      
      unless assignee
        add_error(I18n.t('task_automation.log.assignee_not_found', search_string: assignee_search_string), template_issue.id)
        return nil
      end
      
      Rails.logger.debug "[TaskAutomation] get_assignee: found: #{assignee.class} - #{assignee.name}"
      
      assignee
    end

    # ============================================================================
    # Поиск пользователя или группы по фрагменту имени
    # ============================================================================
    def find_user_or_group_by_name_fragment(search_string)
      return nil unless search_string.present?
      
      search_lower = search_string.downcase
      
      # Сначала ищем среди пользователей (firstname + lastname)
      User.active.each do |user|
        full_name = "#{user.firstname} #{user.lastname}".strip.downcase
        login_name = user.login.downcase
        
        if full_name.include?(search_lower) || login_name.include?(search_lower)
          Rails.logger.debug "[TaskAutomation] find_user_or_group_by_name_fragment: found user: #{user.login} (#{full_name})"
          return user
        end
      end
      
      # Если пользователь не найден, ищем среди групп
      Group.all.each do |group|
        if group.name.downcase.include?(search_lower)
          Rails.logger.debug "[TaskAutomation] find_user_or_group_by_name_fragment: found group: #{group.name}"
          return group
        end
      end
      
      nil
    end

    def create_target_issue(template_issue, target_project, target_tracker, assignee)
      issue = nil
      
      ActiveRecord::Base.transaction do
        issue = Issue.new
        issue.project = target_project
        issue.tracker = target_tracker
        issue.author = User.find(@settings[:author_id])
        issue.subject = template_issue.subject
        issue.description = template_issue.description
        issue.status = target_tracker.default_status
        issue.priority = IssuePriority.default
        
        # ✅ ИЗМЕНЕНО: Дата начала = дате следующего выполнения из шаблона
        date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
        next_date = template_issue.custom_field_value(date_field_id)
        issue.start_date = next_date.to_date if next_date.present?
        
        issue.assigned_to = assignee
        
        # ✅ ОТКЛЮЧАЕМ уведомления перед сохранением
        issue.notify = false
        
        custom_fields_from_description = parse_custom_fields_from_description(template_issue.description)
        unless custom_fields_from_description.empty?
          set_custom_fields(issue, custom_fields_from_description, template_issue.id)
        end
        
        # Первое сохранение
        issue.save!
        Rails.logger.info "[TaskAutomation] create_target_issue: Задача создана - issue_id=#{issue.id}, lock_version=#{issue.lock_version}"
        
        # Копирование вложений
        copy_attachments(template_issue, issue)
        
        Rails.logger.info "[TaskAutomation] create_target_issue: Вложения скопированы - issue_id=#{issue.id}"
      end
      
      # Перезагружаем объект после транзакции
      issue.reload if issue.persisted?
      
      issue
    rescue => e
      add_error(I18n.t('task_automation.log.issue_save_error', error: e.message), template_issue.id)
      Rails.logger.error "[TaskAutomation] create_target_issue: Ошибка - #{e.class}: #{e.message}"
      nil
    end

    def parse_custom_fields_from_description(description)
      return {} unless description.present?
      
      custom_fields = {}
      
      description.lines.each do |line|
        if line.include?(':')
          parts = line.split(':', 2)
          if parts.length == 2
            field_name = parts[0].strip
            field_value = parts[1].strip
            custom_fields[field_name] = field_value unless field_name.blank?
          end
        end
      end
      
      custom_fields
    end

    def set_custom_fields(issue, custom_fields_hash, template_issue_id)
      custom_fields_hash.each do |field_name, field_value|
        field_id = TaskAutomation::Service.get_custom_field_id_by_name(field_name)
        
        unless field_id.present?
          add_error(I18n.t('task_automation.log.field_not_found', field_name: field_name), template_issue_id)
          next
        end
        
        custom_field = CustomField.find_by(id: field_id)
        
        unless custom_field && custom_field.trackers.include?(issue.tracker)
          add_error(I18n.t('task_automation.log.field_not_available', field_name: field_name, tracker_name: issue.tracker.name), template_issue_id)
          next
        end
        
        issue.custom_field_values = { field_id => field_value }
      end
      
      check_required_fields(issue, template_issue_id)
    end

    def check_required_fields(issue, template_issue_id)
      issue.tracker.custom_fields.each do |custom_field|
        if custom_field.is_required
          if issue.custom_field_value(custom_field.id).blank?
            add_error(I18n.t('task_automation.log.required_field_missing', field_name: custom_field.name), template_issue_id)
          end
        end
      end
    end

    def copy_attachments(source_issue, target_issue)
      return unless source_issue.attachments.any?
      
      Rails.logger.info "[TaskAutomation] copy_attachments: Начало - source_id=#{source_issue.id}, target_id=#{target_issue.id}, count=#{source_issue.attachments.count}"
      
      source_issue.attachments.each_with_index do |attachment, index|
        begin
          Rails.logger.info "[TaskAutomation] copy_attachments: Копирование вложения ##{index + 1} - #{attachment.filename}"
          
          # Проверяем существование файла на диске
          unless File.exist?(attachment.diskfile)
            Rails.logger.warn "[TaskAutomation] copy_attachments: Файл не найден - #{attachment.diskfile}"
            next
          end
          
          # Создаем новое вложение
          new_attachment = Attachment.new(
            container: target_issue,
            filename: attachment.filename,
            filesize: attachment.filesize,
            content_type: attachment.content_type,
            description: attachment.description,
            author: User.find(@settings[:author_id])
          )
          
          # Копируем файл через временный файл
          require 'tempfile'
          require 'fileutils'
          
          ext = File.extname(attachment.filename)
          temp_file = Tempfile.new(["attachment_#{Time.now.to_i}_#{index}", ext])
          temp_file.binmode
          
          FileUtils.cp(attachment.diskfile, temp_file.path)
          
          # Открываем временный файл для прикрепления
          temp_file.rewind
          new_attachment.file = temp_file
          
          # Сохраняем вложение
          new_attachment.save!
          
          Rails.logger.info "[TaskAutomation] copy_attachments: Вложение скопировано - #{attachment.filename} (#{attachment.filesize} bytes)"
          
          # Закрываем и удаляем временный файл
          temp_file.close
          temp_file.unlink
          
        rescue => e
          Rails.logger.error "[TaskAutomation] copy_attachments: Ошибка копирования - #{e.class}: #{e.message}"
          Rails.logger.error "[TaskAutomation] copy_attachments: Backtrace: #{e.backtrace.first(3).join("\n")}"
        end
      end
      
      Rails.logger.info "[TaskAutomation] copy_attachments: Завершено"
    end

    def add_watchers(target_issue, template_issue, assignee)
      watcher_ids = []
      watcher_field_id = @custom_field_ids[FIELD_WATCHER_GROUPS]
      
      if watcher_field_id.present?
        watcher_search_string = template_issue.custom_field_value(watcher_field_id)
        
        if watcher_search_string.present?
          watcher_search_string.to_s.split(',').each do |watcher_fragment|
            watcher_fragment = watcher_fragment.strip
            next if watcher_fragment.blank?
            
            watcher = find_user_or_group_by_name_fragment(watcher_fragment)
            
            if watcher
              # ✅ ИСПРАВЛЕНО: Добавляем ID наблюдателя напрямую (и пользователя, и группу)
              watcher_ids << watcher.id
              
              Rails.logger.debug "[TaskAutomation] add_watchers: добавлен наблюдатель #{watcher.class} - #{watcher.name}"
            else
              add_warning(I18n.t('task_automation.log.watcher_not_found', 
                               search_string: watcher_fragment), template_issue.id)
            end
          end
        end
      end
      
      # ✅ ИСПОЛЬЗУЕМ watcher_user_ids= для добавления наблюдателей
      if watcher_ids.any?
        # Исключаем assignee из watcher_ids на всякий случай
        assignee_ids = []
        if assignee.is_a?(User)
          assignee_ids << assignee.id
        elsif assignee.is_a?(Group)
          assignee_ids << assignee.id  # ✅ Добавляем ID группы, а не пользователей
        end
        
        watcher_ids = watcher_ids - assignee_ids
        
        existing_watcher_ids = target_issue.watcher_user_ids
        target_issue.watcher_user_ids = (existing_watcher_ids + watcher_ids).uniq
        target_issue.save!(notifications: false)
        
        Rails.logger.debug "[TaskAutomation] add_watchers: добавлено #{watcher_ids.count} наблюдателей (включая группы)"
      end
    end

    # ============================================================================
    # Добавление наблюдателя без дублирования (используем Watcher.create!)
    # ============================================================================
    def add_watcher_if_not_exists(issue, user)
      # Проверяем, не является ли пользователь уже наблюдателем
      unless issue.watcher_users.include?(user)
         # Используем Watcher.create! для надёжного создания записи
        begin
          Watcher.create!(
            watchable: issue,
            user: user
          )
          Rails.logger.debug "[TaskAutomation] add_watcher_if_not_exists: создан Watcher для user=#{user.login}, issue=#{issue.id}"
        rescue => e
          Rails.logger.warn "[TaskAutomation] add_watcher_if_not_exists: ошибка создания Watcher - #{e.message}"
        end
      end
    end

    # ============================================================================
    # Расчет дат для задачи без подзадач
    # ============================================================================
    def calculate_single_issue_dates(issue, template_issue)
      Rails.logger.info  "[TaskAutomation] calculate_single_issue_dates: НАЧАЛО - issue_id=#{issue.id}, lock_version=#{issue.lock_version} "
      
      duration_field_id = @custom_field_ids[FIELD_DURATION_DAYS]
      end_on_working_day_field_id = @custom_field_ids[FIELD_END_ON_WORKING_DAY]  # ✅ ЗАМЕНЕНО
      
      duration = duration_field_id.present? ?   
                  (template_issue.custom_field_value(duration_field_id).to_i rescue 0) : 0
      
      # ✅ ПРОВЕРКА: Конец в рабочий день
      end_on_working_day = end_on_working_day_field_id.present? && 
                          (template_issue.custom_field_value(end_on_working_day_field_id).to_i == 1)
      
      if duration == 0
        issue.due_date = issue.start_date
      else
        issue.due_date = issue.start_date + duration.days
      end
      
      # ✅ КОРРЕКТИРОВКА: Если "Конец в рабочий день" = да и due_date на выходном
      if end_on_working_day && issue.due_date.present? && !TaskAutomation::Service.working_day?(issue.due_date)
        Rails.logger.info  "[TaskAutomation] calculate_single_issue_dates: due_date выпадает на выходной (#{issue.due_date.strftime('%A')}), сдвигаем НАЗАД "
        
        # Сдвигаем due_date НАЗАД к рабочему дню
        adjusted_due_date = TaskAutomation::Service.shift_to_working_day(issue.due_date, direction: :backward)
        
        # Рассчитываем разницу в днях
        days_shift = (issue.due_date - adjusted_due_date).to_i
        
        # ⚠️ Сдвигаем start_date НАЗАД на ту же разницу (для сохранения длительности)
        issue.start_date = issue.start_date - days_shift.days
        issue.due_date = adjusted_due_date
        
        Rails.logger.info  "[TaskAutomation] calculate_single_issue_dates: Сдвинуто - start_date=#{issue.start_date}, due_date=#{issue.due_date} "
      end
      
      # Перезагружаем перед сохранением!
      #issue.reload
      Rails.logger.info  "[TaskAutomation] calculate_single_issue_dates: После reload - lock_version=#{issue.lock_version} "
      Rails.logger.info  "[TaskAutomation] calculate_single_issue_dates: ПЕРЕД сохранением - due_date=#{issue.due_date} "

      issue.save!(notifications: false)

      Rails.logger.info  "[TaskAutomation] calculate_single_issue_dates: ПОСЛЕ сохранения - due_date=#{issue.due_date} "
    end

    # ============================================================================
    # Расчет даты завершения подзадачи
    # ============================================================================
    def calculate_subtask_due_date(subtask, subtask_template)
      duration_field_id = @custom_field_ids[FIELD_DURATION_DAYS]
      end_on_working_day_field_id = @custom_field_ids[FIELD_END_ON_WORKING_DAY]  # ✅ ЗАМЕНЕНО
      
      duration = duration_field_id.present? ? 
                 (subtask_template.custom_field_value(duration_field_id).to_i rescue 0) : 0
      
      # ✅ ПРОВЕРКА: Конец в рабочий день
      end_on_working_day = end_on_working_day_field_id.present? && 
                          (subtask_template.custom_field_value(end_on_working_day_field_id).to_i == 1)
      
      if duration == 0
        subtask.due_date = subtask.start_date
      else
        subtask.due_date = subtask.start_date + duration.days
      end
      
      # ✅ КОРРЕКТИРОВКА: Если "Конец в рабочий день" = да и due_date на выходном
      if end_on_working_day && subtask.due_date.present? && !TaskAutomation::Service.working_day?(subtask.due_date)
        Rails.logger.info  "[TaskAutomation] calculate_subtask_due_date: due_date выпадает на выходной (#{subtask.due_date.strftime('%A')}), сдвигаем НАЗАД "
        
        adjusted_due_date = TaskAutomation::Service.shift_to_working_day(subtask.due_date, direction: :backward)
        days_shift = (subtask.due_date - adjusted_due_date).to_i
        
        subtask.start_date = subtask.start_date - days_shift.days
        subtask.due_date = adjusted_due_date
        
        Rails.logger.info  "[TaskAutomation] calculate_subtask_due_date: Сдвинуто - start_date=#{subtask.start_date}, due_date=#{subtask.due_date} "
      end
      
      # Перезагружаем перед сохранением
      subtask.reload
      
      subtask.save!(notifications: false)
      subtask.due_date
    end

    # ============================================================================
    # Расчет даты завершения родительской задачи
    # ============================================================================
    def calculate_parent_due_date(parent_issue, template_issue)
      Rails.logger.info "[TaskAutomation] calculate_parent_due_date: НАЧАЛО - parent_issue_id=#{parent_issue.id}, lock_version=#{parent_issue.lock_version}"
      
      subtasks = parent_issue.children
      return if subtasks.empty?
      
      max_due_date = subtasks.map(&:due_date).compact.max
      
      if max_due_date.present?
        parent_issue.due_date = max_due_date
        
        # Перезагружаем перед сохранением
        parent_issue.reload
        
        parent_issue.save!(notifications: false)
        Rails.logger.info "[TaskAutomation] calculate_parent_due_date: УСПЕШНО - due_date=#{parent_issue.due_date}"
      end
    end

    def process_subtasks(template_issue, target_issue, target_project, assignment_group)
      subtasks_created = 0
      subtasks = template_issue.children
      
      unless target_issue.tracker.subtask?
        add_error(I18n.t('task_automation.log.tracker_no_subtasks'), template_issue.id)
        return [false, 0]
      end
      
      sorted_subtasks = sort_subtasks_by_order(subtasks)
      current_start_date = target_issue.start_date
      max_end_date = nil
      grouped_subtasks = sorted_subtasks.group_by { |st| get_subtask_order(st) }
      
      grouped_subtasks.each do |order, group_subtasks|
        group_start_date = current_start_date
        group_max_end = nil
        
        group_subtasks.each do |subtask_template|
          target_subtask = create_target_subtask(
            subtask_template, 
            target_issue, 
            target_project, 
            assignment_group,
            group_start_date
          )
          
          unless target_subtask
             return [false, 0]
          end
      
          subtasks_created += 1
          subtask_end_date = calculate_subtask_due_date(target_subtask, subtask_template)
          
          if group_max_end.blank? || subtask_end_date > group_max_end
            group_max_end = subtask_end_date
          end
        end
        
        if max_end_date.blank? || group_max_end > max_end_date
          max_end_date = group_max_end
        end
        
        current_start_date = group_max_end + 1.day
      end
      
      [true, subtasks_created]
    end

    def sort_subtasks_by_order(subtasks)
      order_field_id = @custom_field_ids[FIELD_SUBTASK_ORDER]
      return subtasks.to_a unless order_field_id.present?
      
      subtasks.sort_by do |subtask|
        order_value = subtask.custom_field_value(order_field_id).to_i
        order_value
      end
    end

    def get_subtask_order(subtask)
      order_field_id = @custom_field_ids[FIELD_SUBTASK_ORDER]
      return 0 unless order_field_id.present?
      
      subtask.custom_field_value(order_field_id).to_i
    end

    def create_target_subtask(subtask_template, parent_issue, target_project, assignment_group, start_date) 
      subtask = Issue.new
      subtask.project = target_project
      
      subtask_tracker = get_target_tracker(subtask_template, target_project)
      
      unless subtask_tracker
        add_error(I18n.t('task_automation.log.subtask_tracker_not_found'), subtask_template.id)
        return nil
      end

      # Соответствие трекера подзадачи настройкам
      if @settings[:subtask_tracker_id].present? && @settings[:subtask_tracker_id].to_i > 0
        unless subtask_tracker.id == @settings[:subtask_tracker_id].to_i
          add_error(I18n.t('task_automation.log.subtask_tracker_mismatch', 
                         expected: @settings[:subtask_tracker_id],
                         actual: subtask_tracker.id), subtask_template.id)
        end
      end
      
      subtask.tracker = subtask_tracker
      subtask.parent_issue = parent_issue
      subtask.author = User.find(@settings[:author_id])
      subtask.subject = subtask_template.subject
      subtask.description = subtask_template.description
      subtask.start_date = start_date
      subtask.assigned_to = assignment_group
      subtask.status = subtask_tracker.default_status
      
      custom_fields = parse_custom_fields_from_description(subtask_template.description)
      unless custom_fields.empty?
        set_custom_fields(subtask, custom_fields, subtask_template.id)
      end
      
      # Сохраняем подзадачу сразу (наблюдатели для подзадач не добавляются)
      subtask.save!(notifications: false)
      copy_attachments(subtask_template, subtask)
      
      subtask
    rescue => e
      add_error(I18n.t('task_automation.log.subtask_save_error', error: e.message), subtask_template.id)
      nil
    end

    def update_next_execution_date(template_issue)
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      unit_field_id = @custom_field_ids[FIELD_INTERVAL_UNIT]
      interval_field_id = @custom_field_ids[FIELD_INTERVAL_VALUE]
      day_number_field_id = @custom_field_ids[FIELD_DAY_NUMBER]
      repeat_days_field_id = @custom_field_ids[FIELD_REPEAT_DAYS]
      month_field_id = @custom_field_ids[FIELD_MONTH]
      
      # ✅ ДОБАВИТЬ ЛОГИРОВАНИЕ ЗНАЧЕНИЙ ПОЛЕЙ
      Rails.logger.info  "[TaskAutomation] update_next_execution_date: ШАБЛОН ##{template_issue.id} "
      Rails.logger.info  "[TaskAutomation]   - current_date: #{template_issue.custom_field_value(date_field_id)} "
      Rails.logger.info  "[TaskAutomation]   - interval_unit: '#{template_issue.custom_field_value(unit_field_id)}' "
      Rails.logger.info  "[TaskAutomation]   - interval_value: #{template_issue.custom_field_value(interval_field_id).to_i} "
      Rails.logger.info  "[TaskAutomation]   - day_number: '#{template_issue.custom_field_value(day_number_field_id)}' "
      Rails.logger.info  "[TaskAutomation]   - repeat_days: '#{template_issue.custom_field_value(repeat_days_field_id)}' "
      Rails.logger.info  "[TaskAutomation]   - month: '#{template_issue.custom_field_value(month_field_id)}' "
      # ✅ КОНЕЦ ЛОГИРОВАНИЯ
      
      return unless date_field_id.present?
      
      current_date = template_issue.custom_field_value(date_field_id)
      return unless current_date.present?
      
      current_date = current_date.to_date
      
      interval_unit = unit_field_id.present? ? 
                     template_issue.custom_field_value(unit_field_id) : nil
      
      interval_value = interval_field_id.present? ? 
                      (template_issue.custom_field_value(interval_field_id).to_i rescue 1) : 1
      
      new_date = nil
      
      case interval_unit
      when 'год', 'year', 'год'
        new_date = calculate_yearly_date(current_date, interval_value, 
                                        template_issue, day_number_field_id,
                                        repeat_days_field_id, month_field_id)
      when 'месяц', 'month'
        new_date = calculate_monthly_date(current_date, interval_value,
                                         template_issue, day_number_field_id,
                                         repeat_days_field_id)
      when 'неделя', 'week'
        new_date = calculate_weekly_date(current_date, interval_value,
                                         template_issue, repeat_days_field_id)
      when 'день', 'day'
        new_date = calculate_daily_date(current_date, interval_value)
      else
        new_date = calculate_daily_date(current_date, interval_value)
      end
      
      if new_date.present?
        template_issue.custom_field_values = { date_field_id => new_date }
        template_issue.save!(notifications: false)
        
        Rails.logger.info  "[TaskAutomation] update_next_execution_date: НОВАЯ ДАТА: #{new_date} "
      end
    end

    def calculate_yearly_date(current_date, interval, template_issue, day_number_field_id, repeat_days_field_id, month_field_id)
      begin
        month_field_value = month_field_id.present? ? 
                           template_issue.custom_field_value(month_field_id) : nil
        day_number = day_number_field_id.present? ? 
                    (template_issue.custom_field_value(day_number_field_id).to_i rescue nil) : nil
        repeat_days = repeat_days_field_id.present? ? 
                       template_issue.custom_field_value(repeat_days_field_id) : nil
        
        if month_field_value.present?
          month_num = month_name_to_number(month_field_value)
          
          if repeat_days.present?
            day_num = repeat_day_name_to_number(repeat_days)
            new_date = find_nth_weekday_in_month(current_date.year + interval, month_num, day_num)
             
            unless new_date
              add_error(I18n.t('task_automation.log.invalid_weekday_in_month'), template_issue.id)
              return current_date + interval.years
            end
          elsif day_number.present?
            new_date = Date.new(current_date.year + interval, month_num, day_number)
          else
            add_error(I18n.t('task_automation.log.month_without_day'), template_issue.id)
            return current_date + interval.years
          end
        else
          new_date = current_date + interval.years
        end
        
        new_date
      rescue => e
        add_error(I18n.t('task_automation.log.date_calculation_error', error: e.message), template_issue.id)
        current_date + interval.years
      end
    end

    def calculate_monthly_date(current_date, interval, template_issue, day_number_field_id, repeat_days_field_id)
      begin
        # Получаем сырые значения из кастомных полей
        day_number_raw = day_number_field_id.present? ? 
                        template_issue.custom_field_value(day_number_field_id) : nil
        repeat_days_raw = repeat_days_field_id.present? ? 
                         template_issue.custom_field_value(repeat_days_field_id) : nil
        
        # ✅ ПРАВИЛЬНАЯ конвертация: пустая строка → nil, не 0!
        day_number = day_number_raw.present? ? day_number_raw.to_i : nil
        
        # ✅ Парсим JSON или оставляем как строку
        repeat_days = case repeat_days_raw
                      when Array
                        repeat_days_raw.join(',')
                      when String
                        # Пробуем распарсить JSON
                        begin
                          parsed = JSON.parse(repeat_days_raw)
                          parsed.is_a?(Array) ? parsed.join(',') : repeat_days_raw
                        rescue JSON::ParserError
                          repeat_days_raw
                        end
                      else
                        nil
                      end
        
        # Расчет целевого месяца
        target_month = current_date.month + interval
        target_year = current_date.year
        
        while target_month > 12
          target_month -= 12
          target_year += 1
        end
        
        # ✅ СЛУЧАЙ 1: Поля не заполнены → просто добавляем интервал
        # 10 марта → 10 апреля
        if day_number.blank? && repeat_days.blank?
          max_day = Date.new(target_year, target_month, -1).day
          target_day = [current_date.day, max_day].min
          return Date.new(target_year, target_month, target_day)
        end
        
        # ✅ СЛУЧАЙ 2: "Первый понедельник" (число=1 + дни повторения)
        if day_number == 1 && repeat_days.present?
          day_num = repeat_day_name_to_number(repeat_days)
          new_date = find_nth_weekday_in_month(target_year, target_month, day_num)
          return new_date if new_date
        end
        
        # ✅ СЛУЧАЙ 3: Конкретное число месяца (ОСНОВНОЙ СЛУЧАЙ)
        if day_number.present? && day_number > 0
          max_day = Date.new(target_year, target_month, -1).day
          
          # Если числа нет в месяце → берем последнее число
          if day_number > max_day
            new_date = Date.new(target_year, target_month, max_day)
          else
            new_date = Date.new(target_year, target_month, day_number)
          end
          
          # ⚠️ "Дни повторения" НЕ влияют на расчет следующей даты!
          return new_date
        end
        
        # ✅ СЛУЧАЙ 4: Только дни повторения без числа
        if repeat_days.present?
          day_num = repeat_day_name_to_number(repeat_days)
          new_date = find_nth_weekday_in_month(target_year, target_month, day_num)
          return new_date if new_date
        end
        
        # Запасной вариант
        current_date >> interval
        
      rescue => e
        add_error(I18n.t('task_automation.log.date_calculation_error', error: e.message), template_issue.id)
        current_date >> interval
      end
    end

    def calculate_weekly_date(current_date, interval, template_issue, repeat_days_field_id)
      begin
        repeat_days = repeat_days_field_id.present? ? 
                       template_issue.custom_field_value(repeat_days_field_id) : nil
        
        if repeat_days.blank?
          return current_date + interval.weeks
        end
        
        days_list = repeat_days.split(/[;,]/).map(&:strip)
        
        if days_list.length > 1 && interval != 1
          add_error(I18n.t('task_automation.log.multiple_days_invalid_interval'), template_issue.id)
          return current_date + interval.weeks
        end
        
        if days_list.length == 1
          day_num = repeat_day_name_to_number(days_list.first)
          new_date = current_date + interval.weeks
          
          while new_date.wday != day_num
            new_date += 1.day
          end
        else
          weekdays = days_list.map { |d| repeat_day_name_to_number(d) }
          new_date = current_date + 1.day
          
          while !weekdays.include?(new_date.wday)
            new_date += 1.day
          end
        end
        
        new_date
      rescue => e
        add_error(I18n.t('task_automation.log.date_calculation_error', error: e.message), template_issue.id)
        current_date + interval.weeks
      end
    end

    def calculate_daily_date(current_date, interval)
      current_date + interval.days
    end

    def month_name_to_number(month_name)
      months = {
        'янв' => 1, 'январь' => 1, 'jan' => 1, 'january' => 1,
        'фев' => 2, 'февраль' => 2, 'feb' => 2, 'february' => 2,
        'мар' => 3, 'март' => 3, 'mar' => 3, 'march' => 3,
        'апр' => 4, 'апрель' => 4, 'apr' => 4, 'april' => 4,
        'май' => 5, 'may' => 5,
        'июн' => 6, 'июнь' => 6, 'jun' => 6, 'june' => 6,
        'июл' => 7, 'июль' => 7, 'jul' => 7, 'july' => 7,
        'авг' => 8, 'август' => 8, 'aug' => 8, 'august' => 8,
        'сен' => 9, 'сентябрь' => 9, 'sep' => 9, 'september' => 9,
        'окт' => 10, 'октябрь' => 10, 'oct' => 10, 'october' => 10,
        'ноя' => 11, 'ноябрь' => 11, 'nov' => 11, 'november' => 11,
        'дек' => 12, 'декабрь' => 12, 'dec' => 12, 'december' => 12
      }
      
      months[month_name.to_s.downcase.strip] || 1
    end

    def repeat_day_name_to_number(day_name)
      days = {
        'пн' => 1, 'пон' => 1, 'понедельник' => 1, 'mon' => 1, 'monday' => 1,
        'вт' => 2, 'втор' => 2, 'вторник' => 2, 'tue' => 2, 'tuesday' => 2,
        'ср' => 3, 'сред' => 3, 'среда' => 3, 'wed' => 3, 'wednesday' => 3,
        'чт' => 4, 'четв' => 4, 'четверг' => 4, 'thu' => 4, 'thursday' => 4,
        'пт' => 5, 'пят' => 5, 'пятница' => 5, 'fri' => 5, 'friday' => 5,
        'сб' => 6, 'суб' => 6, 'суббота' => 6, 'sat' => 6, 'saturday' => 6,
        'вс' => 0, 'воск' => 0, 'воскресенье' => 0, 'sun' => 0, 'sunday' => 0
      }
      
      days[day_name.to_s.downcase.strip] || 1
    end

    def find_nth_weekday_in_month(year, month, weekday_num)
      date = Date.new(year, month, 1)
      count = 0
      
      while date.month == month
        if date.wday == weekday_num
          count += 1
          return date if count >= 1
        end
        date += 1.day
      end
      
      nil
    end

    def log_summary
      if @created_issues_count > 0
        TaskAutomation::Service.log_message('info',
          I18n.t('task_automation.log.summary_success', 
                 issues: @created_issues_count,
                 subtasks: @created_subtasks_count))
      else
        TaskAutomation::Service.log_message('info',
          I18n.t('task_automation.log.summary_no_tasks'))
      end
    end

    # ============================================================================
    # Отправка уведомлений о создании задачи наблюдателям и назначенному
    # ============================================================================
    def send_creation_notifications(issue, template_issue_id)
      begin
        if Setting.notified_events.include?('issue_added')
          # Перезагружаем задачу для обновления кэша ассоциаций
          issue.reload
          
          # ✅ ЛОГИРОВАНИЕ: Кто получит уведомления
          notified_users = issue.notified_users.map(&:login)
          notified_watchers = issue.notified_watchers.map(&:login)
          all_recipients = (issue.notified_users | issue.notified_watchers | issue.notified_mentions).map(&:login)
          
          Rails.logger.info "[TaskAutomation] send_creation_notifications: issue_id=#{issue.id}"
          Rails.logger.info "[TaskAutomation]   notified_users: #{notified_users.join(', ')}"
          Rails.logger.info "[TaskAutomation]   notified_watchers: #{notified_watchers.join(', ')}"
          Rails.logger.info "[TaskAutomation]   all_recipients (после dedup): #{all_recipients.join(', ')}"
          Rails.logger.info "[TaskAutomation]   assigned_to: #{issue.assigned_to&.login}"
          
          # Используем встроенный метод Redmine
          Mailer.deliver_issue_add(issue)
          
          TaskAutomation::Service.log_message('info',
            I18n.t('task_automation.log.notifications_sent', issue_id: issue.id),
            issue.id)
        end
      rescue => e
        add_warning(I18n.t('task_automation.log.notification_error', 
                           error: e.message), template_issue_id)
        Rails.logger.error "[TaskAutomation] send_creation_notifications: #{e.class}: #{e.message}"
      end
    end

    def build_result(success)
      {
        success: success,
        processed_count: @created_issues_count,
        created_count: @created_issues_count,
        subtasks_count: @created_subtasks_count,
        errors: @errors,
        warnings: @warnings,
        messages: @messages
      }
    end

    # ============================================================================
    # Публичный метод для получения списка предупреждений текущего запуска
    # ============================================================================
    def collected_warnings
      @warnings
    end

    # ============================================================================
    # Проверка наличия предупреждений
    # ============================================================================
    def has_warnings?
      @warnings.any?
    end

    def has_errors?
      @errors.any?
    end

    # ============================================================================
    # Публичный метод для получения списка ошибок текущего запуска
    # Возвращает массив строк в формате: [2026-03-08 15:18:33] [ERROR] [Issue #1] Текст
    # ============================================================================
    def collected_errors
      @errors
    end

    # ============================================================================
    # Публичный метод для получения всех ошибок и предупреждений текущего запуска
    # Возвращает массив строк в хронологическом порядке (только ERROR и WARNING)
    # НЕ включает сообщения уровня INFO
    # ============================================================================
    def collected_errors_and_warnings
      # Объединяем ошибки и предупреждения в хронологическом порядке
      (@errors + @warnings).sort
    end

    # ============================================================================
    # Проверка наличия ошибок или предупреждений
    # ============================================================================
    def has_errors_or_warnings?
      @errors.any? || @warnings.any?
    end
  end
end