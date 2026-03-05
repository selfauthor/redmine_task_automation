# ============================================================================
# Файл: lib/task_automation/task_processor.rb
# Назначение: Основной процессор бизнес-логики для автоматизации задач
# ============================================================================

module TaskAutomation
  class TaskProcessor
    # Явно включаем модуль конфигурации
    include TaskAutomation::Configuration

    # ============================================================================
    # Подключение модуля конфигурации для доступа к константам
    # ============================================================================
    include TaskAutomation::Configuration
    
    # ============================================================================
    # Инициализация процессора
    # ============================================================================
    def initialize
      @errors = []
      @messages = []
      @created_issues_count = 0
      @created_subtasks_count = 0
      @settings = TaskAutomation::Service.get_settings
      @custom_field_ids = {}
      
      initialize_custom_field_cache
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
          TaskAutomation::Service.log_message('error', 
            I18n.t('task_automation.log.template_processing_error', 
                   issue_id: template_issue.id, 
                   error: e.message))
          @errors << I18n.t('task_automation.log.template_processing_error', 
                           issue_id: template_issue.id, 
                           error: e.message)
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
      
      # Шаг 3.1: Проверка проекта назначения
      target_project = get_target_project(template_issue)
      
      unless target_project
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.project_not_found'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.project_not_found')
        return
      end
      
      # Шаг 3.2: Проверка трекера
      target_tracker = get_target_tracker(template_issue, target_project)
      
      unless target_tracker
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.tracker_not_found'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.tracker_not_found')
        return
      end
      
      # Шаг 3.3: Проверка группы назначения
      assignment_group = get_assignment_group(template_issue)
      
      unless assignment_group && TaskAutomation::Service.group_can_be_assigned?(assignment_group.name, target_project.id)
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.group_not_found'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.group_not_found')
        return
      end
      
      # Шаг 3.4-3.6: Создание целевой задачи
      target_issue = create_target_issue(template_issue, target_project, target_tracker, assignment_group)
      
      unless target_issue
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.issue_creation_failed'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.issue_creation_failed')
        return
      end
      
      # Шаг 3.7: Добавление наблюдателей
      add_watchers(target_issue, template_issue, assignment_group)
      
      # Шаг 3.8: Обработка подзадач
      has_subtasks = template_issue.children.any?
      
      if has_subtasks
        success, subtasks_count = process_subtasks(template_issue, target_issue, target_project, assignment_group)
        
        unless success
          target_issue.destroy
          TaskAutomation::Service.log_message('error',
            I18n.t('task_automation.log.subtask_processing_failed'),
            template_issue.id)
          @errors << I18n.t('task_automation.log.subtask_processing_failed')
          return
        end
        
        @created_subtasks_count += subtasks_count
        calculate_parent_due_date(target_issue, template_issue)
      else
        calculate_single_issue_dates(target_issue, template_issue)
      end
      
      # Шаг 3.9: Логирование успешного создания задачи
      subtask_message = has_subtasks ? 
        I18n.t('task_automation.log.with_subtasks', count: target_issue.children.count) : ''
      
      TaskAutomation::Service.log_message('info',
        I18n.t('task_automation.log.issue_created', 
               issue_id: target_issue.id,
               subject: target_issue.subject,
               subtasks: subtask_message),
        target_issue.id)
      
      @created_issues_count += 1
      
      # Шаг 3.10: Обновление даты следующего выполнения в шаблоне
      update_next_execution_date(template_issue)
    end
    
    # ============================================================================
    # Вспомогательные методы (полный код из предыдущей версии)
    # ============================================================================
    def get_target_project(template_issue)
      project_field_id = @custom_field_ids[FIELD_TARGET_PROJECT]
      return nil unless project_field_id.present?
      
      project_id = template_issue.custom_field_value(project_field_id).to_i
      return nil unless TaskAutomation::Service.project_exists?(project_id)
      
      Project.find(project_id)
    end
    
    def get_target_tracker(template_issue, target_project)
      tracker_field_id = @custom_field_ids[FIELD_TARGET_TRACKER]
      return nil unless tracker_field_id.present?
      
      tracker_name = template_issue.custom_field_value(tracker_field_id)
      return nil unless tracker_name.present?
      
      tracker = Tracker.find_by(name: tracker_name)
      return nil unless tracker && target_project.trackers.include?(tracker)
      
      tracker
    end
    
    def get_assignment_group(template_issue)
      group_field_id = @custom_field_ids[FIELD_ASSIGNMENT_GROUP]
      return nil unless group_field_id.present?
      
      group_name = template_issue.custom_field_value(group_field_id)
      return nil unless group_name.present?
      
      TaskAutomation::Service.get_group_by_name(group_name)
    end
    
    def create_target_issue(template_issue, target_project, target_tracker, assignment_group)
      issue = Issue.new
      issue.project = target_project
      issue.tracker = target_tracker
      issue.author = User.find(@settings[:author_id])
      issue.subject = template_issue.subject
      issue.description = template_issue.description
      issue.status = target_tracker.default_status
      issue.priority = IssuePriority.default
      issue.start_date = Date.today
      issue.assigned_to = assignment_group
      
      custom_fields_from_description = parse_custom_fields_from_description(template_issue.description)
      unless custom_fields_from_description.empty?
        set_custom_fields(issue, custom_fields_from_description, template_issue.id)
      end
      
      issue.save!(notifications: false)
      copy_attachments(template_issue, issue)
      issue.save!(notifications: false)
      
      issue
    rescue => e
      TaskAutomation::Service.log_message('error',
        I18n.t('task_automation.log.issue_save_error', error: e.message),
        template_issue.id)
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
          TaskAutomation::Service.log_message('warning',
            I18n.t('task_automation.log.field_not_found', field_name: field_name),
            template_issue_id)
          @errors << I18n.t('task_automation.log.field_not_found', field_name: field_name)
          next
        end
        
        custom_field = CustomField.find_by(id: field_id)
        
        unless custom_field && custom_field.trackers.include?(issue.tracker)
          TaskAutomation::Service.log_message('warning',
            I18n.t('task_automation.log.field_not_available', field_name: field_name),
            template_issue_id)
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
            TaskAutomation::Service.log_message('error',
              I18n.t('task_automation.log.required_field_missing', field_name: custom_field.name),
              template_issue_id)
            @errors << I18n.t('task_automation.log.required_field_missing', field_name: custom_field.name)
          end
        end
      end
    end
    
    def copy_attachments(source_issue, target_issue)
      return unless source_issue.attachments.any?
      
      source_issue.attachments.each do |attachment|
        Attachment.create!(
          container: target_issue,
          file: attachment.file,
          filename: attachment.filename,
          filesize: attachment.filesize,
          content_type: attachment.content_type,
          description: attachment.description,
          author: User.find(@settings[:author_id])
        )
      end
    end
    
    def add_watchers(target_issue, template_issue, assignment_group)
      watcher_field_id = @custom_field_ids[FIELD_WATCHER_GROUPS]
      
      if watcher_field_id.present?
        watcher_groups = template_issue.custom_field_value(watcher_field_id)
        
        if watcher_groups.present?
          watcher_groups.split(/[;,]/).each do |group_name|
            group_name = group_name.strip
            group = TaskAutomation::Service.get_group_by_name(group_name)
            
            if group
              group.users.each do |user|
                target_issue.watcher_users << user unless target_issue.watcher_users.include?(user)
              end
            end
          end
        end
      end
      
      assignment_group.users.each do |user|
        target_issue.watcher_users << user unless target_issue.watcher_users.include?(user)
      end
    end
    
    def process_subtasks(template_issue, target_issue, target_project, assignment_group)
      subtasks_created = 0
      subtasks = template_issue.children
      
      unless target_issue.tracker.subtask?
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.tracker_no_subtasks'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.tracker_no_subtasks')
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
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.subtask_tracker_not_found'),
          subtask_template.id)
        @errors << I18n.t('task_automation.log.subtask_tracker_not_found')
        return nil
      end

      # ==========================================================================
      # Соответствие трекера подзадачи настройкам
      # ==========================================================================
      if @settings[:subtask_tracker_id].present? && @settings[:subtask_tracker_id].to_i > 0
        unless subtask_tracker.id == @settings[:subtask_tracker_id].to_i
          TaskAutomation::Service.log_message('warning',
            I18n.t('task_automation.log.subtask_tracker_mismatch', 
                   expected: @settings[:subtask_tracker_id],
                   actual: subtask_tracker.id),
            subtask_template.id)
          @errors << I18n.t('task_automation.log.subtask_tracker_mismatch', 
                           expected: @settings[:subtask_tracker_id],
                           actual: subtask_tracker.id)
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
      
      subtask.save!(notifications: false)
      copy_attachments(subtask_template, subtask)
      subtask.save!(notifications: false)
      
      subtask
    rescue => e
      TaskAutomation::Service.log_message('error',
        I18n.t('task_automation.log.subtask_save_error', error: e.message),
        subtask_template.id)
      nil
    end
    
    def calculate_single_issue_dates(issue, template_issue)
      duration_field_id = @custom_field_ids[FIELD_DURATION_DAYS]
      working_days_field_id = @custom_field_ids[FIELD_WORKING_DAYS_ONLY]
      
      duration = duration_field_id.present? ? 
                 (template_issue.custom_field_value(duration_field_id).to_i rescue 0) : 0
      
      working_days_only = working_days_field_id.present? && 
                         (template_issue.custom_field_value(working_days_field_id).to_i == 1)
      
      if duration == 0
        issue.due_date = issue.start_date
      elsif working_days_only
        due_date = issue.start_date
        duration.times { due_date = TaskAutomation::Service.shift_to_working_day(due_date + 1.day, direction: :forward) }
        issue.due_date = due_date
      else
        issue.due_date = issue.start_date + duration.days
      end
      
      issue.save!(notifications: false)
    end
    
    def calculate_subtask_due_date(subtask, subtask_template)
      duration_field_id = @custom_field_ids[FIELD_DURATION_DAYS]
      working_days_field_id = @custom_field_ids[FIELD_WORKING_DAYS_ONLY]
      
      duration = duration_field_id.present? ? 
                 (subtask_template.custom_field_value(duration_field_id).to_i rescue 0) : 0
      
      working_days_only = working_days_field_id.present? && 
                         (subtask_template.custom_field_value(working_days_field_id).to_i == 1)
      
      if duration == 0
        subtask.due_date = subtask.start_date
      elsif working_days_only
        due_date = subtask.start_date
        duration.times { due_date = TaskAutomation::Service.shift_to_working_day(due_date + 1.day, direction: :forward) }
        subtask.due_date = due_date
      else
        subtask.due_date = subtask.start_date + duration.days
      end
      
      subtask.save!(notifications: false)
      subtask.due_date
    end
    
    def calculate_parent_due_date(parent_issue, template_issue)
      subtasks = parent_issue.children
      return if subtasks.empty?
      
      max_due_date = subtasks.map(&:due_date).compact.max
      
      if max_due_date.present?
        parent_issue.due_date = max_due_date
        parent_issue.save!(notifications: false)
      end
    end
    
    def update_next_execution_date(template_issue)
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      unit_field_id = @custom_field_ids[FIELD_INTERVAL_UNIT]
      interval_field_id = @custom_field_ids[FIELD_INTERVAL_VALUE]
      day_number_field_id = @custom_field_ids[FIELD_DAY_NUMBER]
      repeat_days_field_id = @custom_field_ids[FIELD_REPEAT_DAYS]
      month_field_id = @custom_field_ids[FIELD_MONTH]
      
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
              TaskAutomation::Service.log_message('error',
                I18n.t('task_automation.log.invalid_weekday_in_month'),
                template_issue.id)
              return current_date + interval.years
            end
          elsif day_number.present?
            new_date = Date.new(current_date.year + interval, month_num, day_number)
          else
            TaskAutomation::Service.log_message('error',
              I18n.t('task_automation.log.month_without_day'),
              template_issue.id)
            return current_date + interval.years
          end
        else
          new_date = current_date + interval.years
        end
        
        new_date
      rescue => e
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.date_calculation_error', error: e.message),
          template_issue.id)
        current_date + interval.years
      end
    end
    
    def calculate_monthly_date(current_date, interval, template_issue, day_number_field_id, repeat_days_field_id)
      begin
        day_number = day_number_field_id.present? ? 
                    (template_issue.custom_field_value(day_number_field_id).to_i rescue nil) : nil
        repeat_days = repeat_days_field_id.present? ? 
                     template_issue.custom_field_value(repeat_days_field_id) : nil
        
        target_month = current_date.month + interval
        target_year = current_date.year
        
        while target_month > 12
          target_month -= 12
          target_year += 1
        end
        
        if repeat_days.present?
          day_num = repeat_day_name_to_number(repeat_days)
          new_date = find_nth_weekday_in_month(target_year, target_month, day_num)
          
          unless new_date
            TaskAutomation::Service.log_message('error',
              I18n.t('task_automation.log.invalid_weekday_in_month'),
              template_issue.id)
            return Date.new(target_year, target_month, -1)
          end
        elsif day_number.present?
          max_day = Date.new(target_year, target_month, -1).day
          
          if day_number == 0
            new_date = Date.new(target_year, target_month, -1)
          elsif day_number > max_day
            new_date = Date.new(target_year, target_month, max_day)
          else
            new_date = Date.new(target_year, target_month, day_number)
          end
        else
          new_date = current_date >> interval
        end
        
        new_date
      rescue => e
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.date_calculation_error', error: e.message),
          template_issue.id)
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
          TaskAutomation::Service.log_message('error',
            I18n.t('task_automation.log.multiple_days_invalid_interval'),
            template_issue.id)
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
        TaskAutomation::Service.log_message('error',
          I18n.t('task_automation.log.date_calculation_error', error: e.message),
          template_issue.id)
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
    
    def build_result(success)
      {
        success: success,
        processed_count: @created_issues_count,
        created_count: @created_issues_count,
        subtasks_count: @created_subtasks_count,
        errors: @errors,
        messages: @messages
      }
    end
    
    def has_errors?
      @errors.any?
    end
  end
end