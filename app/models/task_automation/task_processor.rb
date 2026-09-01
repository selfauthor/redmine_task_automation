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
      @error_templates_count = 0
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
      @error_templates_count += 1 if issue_id.present?
      
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
      
      # ✅ ШАГ 0: Предварительная корректировка дат следующего выполнения
      # Для ВСЕХ шаблонов, где next_execution_date < start_date
      # Эта проверка выполняется ДО основного поиска задач для обработки
      adjust_next_dates_before_start_dates
      
      # ✅ ШАГ 1: Поиск задач-шаблонов для обработки
      # Теперь дата начала НЕ учитывается в фильтре
      template_issues = find_template_issues
      if template_issues.empty?
        TaskAutomation::Service.log_message('info', I18n.t('task_automation.log.no_templates_found'))
        return build_result(true)
      end
      
      # ✅ ШАГ 2: Обработка найденных шаблонов
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
    # Предварительная корректировка дат следующего выполнения
    # 
    # Находит ВСЕ задачи-шаблоны в проекте-источнике, у которых:
    #   - Дата следующего выполнения (custom field) < Даты начала (start_date)
    #   - Дата начала задана (не nil)
    #
    # Для таких задач выполняет корректировку даты следующего выполнения
    # вперёд (итеративно применяя интервал), пока она не станет >= start_date.
    #
    # Записывает WARNING в лог-файл (без отправки администраторам) и создаёт
    # запись в журнале шаблона с уведомлением наблюдателей.
    # ============================================================================
    def adjust_next_dates_before_start_dates
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      return unless date_field_id.present?
      
      # Находим ВСЕ задачи в проекте-источнике с нужным трекером
      # Без фильтра по статусу, дате начала, дате завершения и т.д.
      all_template_issues = Issue.where(
        project_id: @settings[:source_project_id],
        tracker_id: @settings[:tracker_id]
      )
      
      adjusted_count = 0
      
      all_template_issues.each do |template_issue|
        begin
          # Получаем дату начала из стандартного поля
          start_date = template_issue.start_date
          next unless start_date.present?
          
          # Получаем дату следующего выполнения
          next_execution_date = template_issue.custom_field_value(date_field_id)
          next unless next_execution_date.present?
          next_execution_date = next_execution_date.to_date
          
          # Проверяем: если next_execution_date >= start_date, пропускаем
          next if next_execution_date >= start_date
          
          # ✅ Дата следующего выполнения раньше даты начала — нужно скорректировать
          # Получаем интервал для корректировки
          interval_unit_field_id = @custom_field_ids[FIELD_INTERVAL_UNIT]
          interval_unit = interval_unit_field_id.present? ? 
                          template_issue.custom_field_value(interval_unit_field_id) : 'день'
          
          # Вызываем метод корректировки
          if check_and_adjust_next_date_vs_start_date(template_issue, interval_unit)
            adjusted_count += 1
          end
          
        rescue => e
          # Не прерываем обработку остальных задач при ошибке
          Rails.logger.error "[TaskAutomation] adjust_next_dates_before_start_dates: " \
                             "Ошибка при обработке шаблона ##{template_issue.id}: #{e.message}"
        end
      end
      
      if adjusted_count > 0
        TaskAutomation::Service.log_message('info',
          I18n.t('task_automation.log.start_date_adjustment_summary', count: adjusted_count))
      end
    end

    # ============================================================================
    # Метод проверки валидности настроек плагина
    # ============================================================================
    def validate_settings
      result = TaskAutomation::Service.validate_plugin_settings(@settings)
      
      result[:errors].each { |error| @errors << error }
      
      result[:valid]
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
        
        # а) Статус задачи должен быть "открыт" (не закрыт)
        next if issue.status.is_closed
        
        # ✅ УДАЛЕНА ПРОВЕРКА: Дата начала больше не фильтрует задачи
        # Ранее было: next if issue.start_date.present? && issue.start_date > today
        
        # б) Дата завершения: пустая ИЛИ сегодня ИЛИ в будущем
        #    Если в прошлом (просрочена) → пропускаем
        next if issue.due_date.present? && issue.due_date < today
        
        # в) Проверяем дату следующего выполнения с учётом "Создать заранее"
        next unless next_date.present?
        (next_date.to_date - ahead_days.days) <= today
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
        # ✅ ШАГ 1: Проверка проекта назначения
        project_field_id = @custom_field_ids[FIELD_TARGET_PROJECT]
        project_fragment = template_issue.custom_field_value(project_field_id) if project_field_id.present?
        target_project = TaskAutomation::Service.get_target_project_by_fragment(
          project_fragment, @custom_field_ids)

        # ✅ ИСПРАВЛЕНО: Добавляем ошибку если проект не найден
        unless target_project
          error_text = I18n.t('task_automation.log.project_not_found', 
                           field_name: FIELD_TARGET_PROJECT,
                           field_value: project_fragment.to_s)
          add_error(error_text, template_issue.id)
          # ✅ ИЗМЕНЕНО: записываем ошибку в журнал шаблона с рассылкой уведомлений
          log_error_in_template_history(template_issue, error_text)
          return
        end

        # ✅ ШАГ 2: Проверка трекера
        tracker_field_id = @custom_field_ids[FIELD_TARGET_TRACKER]
        tracker_name = template_issue.custom_field_value(tracker_field_id) if tracker_field_id.present?
        target_tracker = TaskAutomation::Service.get_target_tracker_by_name(
          tracker_name, target_project, @custom_field_ids)

        # ✅ ИСПРАВЛЕНО: Добавляем ошибку если трекер не найден
        unless target_tracker
          error_text = I18n.t('task_automation.log.tracker_not_found', 
                           field_name: FIELD_TARGET_TRACKER,
                           tracker_name: tracker_name.to_s)
          add_error(error_text, template_issue.id)
          # ✅ ИЗМЕНЕНО: записываем ошибку в журнал шаблона с рассылкой уведомлений
          log_error_in_template_history(template_issue, error_text)
          return
        end

        # ✅ ШАГ 3: Проверка назначения
        assignee_field_id = @custom_field_ids[FIELD_ASSIGNMENT_GROUP]
        assignee_search_string = template_issue.custom_field_value(assignee_field_id) if assignee_field_id.present?
        assignee = TaskAutomation::Service.get_assignee_by_search_string(
          assignee_search_string, @custom_field_ids)

        # ✅ ИСПРАВЛЕНО: Добавляем ошибку если назначенный не найден
        unless assignee
          error_text = I18n.t('task_automation.log.assignee_not_found', 
                           field_name: FIELD_ASSIGNMENT_GROUP,
                           search_string: assignee_search_string.to_s)
          add_error(error_text, template_issue.id)
          # ✅ ИЗМЕНЕНО: записываем ошибку в журнал шаблона с рассылкой уведомлений
          log_error_in_template_history(template_issue, error_text)
          return
        end

        # ✅ НОВАЯ ПРОВЕРКА: Может ли назначенный быть назначен в проекте
        assignee_validation = TaskAutomation::Service.validate_assignee_for_project(assignee, target_project)
        unless assignee_validation[:valid]
          error_text = assignee_validation[:error]
          add_error(error_text, template_issue.id)
          # ✅ ИЗМЕНЕНО: записываем ошибку в журнал шаблона с рассылкой уведомлений
          log_error_in_template_history(template_issue, error_text)
          return
        end

        # ✅ ШАГ 4: Валидация трекеров подзадач (ИЗ service.rb)
        if template_issue.children.any?
          subtask_validation = TaskAutomation::Service.validate_subtask_trackers(
            template_issue, target_project, @custom_field_ids)
          unless subtask_validation[:valid]
            # ✅ ИЗМЕНЕНО: записываем КАЖДУЮ ошибку в журнал шаблона с уведомлениями
            subtask_validation[:errors].each do |error|
              add_error(error, template_issue.id)
              log_error_in_template_history(template_issue, error)
            end
            return
          end
        end

        # ✅ ШАГ 5: Валидация дополнительных полей периодичности
        interval_unit_field_id = @custom_field_ids[FIELD_INTERVAL_UNIT]
        interval_unit = interval_unit_field_id.present? ? 
                        template_issue.custom_field_value(interval_unit_field_id) : 'день'

        validation_result = validate_additional_fields(template_issue, interval_unit)
        unless validation_result[:valid]
          # ✅ ИЗМЕНЕНО: записываем КАЖДУЮ ошибку в журнал шаблона с уведомлениями
          validation_result[:errors].each do |error|
            add_error(error, template_issue.id)
            log_error_in_template_history(template_issue, error)
          end
          return
        end
        validation_result[:warnings].each do |warning|
          add_warning(warning, template_issue.id)
        end

        # ✅ ШАГ 6: Проверка соответствия даты расписанию
        date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
        schedule_check = check_date_matches_schedule(template_issue, interval_unit)
        unless schedule_check[:matches]
          old_date = template_issue.custom_field_value(date_field_id)
          update_next_execution_date_to(template_issue, schedule_check[:next_valid_date])
          log_task_creation_in_template_history(
            template_issue, 
            nil,
            old_date, 
            schedule_check[:next_valid_date]
          )
          add_warning(I18n.t('task_automation.validation.date_not_matching_schedule', 
                            new_date: schedule_check[:next_valid_date].strftime('%Y-%m-%d')), 
                      template_issue.id)
          return
        end

        # ✅ ШАГ 7: Создание целевой задачи
        target_issue = create_target_issue(template_issue, target_project, target_tracker, assignee)
        return unless target_issue

        # Шаг 3.7: Добавление наблюдателей (вычисляем один раз для родителя и всех подзадач)
        target_issue.reload
        watcher_ids = calculate_watcher_ids(template_issue, assignee)
        add_watchers_to_issue(target_issue, watcher_ids)
        target_issue.reload
        target_issue.reload

        # Шаг 3.8: Обработка подзадач
        has_subtasks = template_issue.children.any?
        if has_subtasks
          success, subtasks_count = process_subtasks(template_issue, target_issue, target_project, assignee, watcher_ids)
          unless success
            target_issue.destroy
            error_text = I18n.t('task_automation.log.subtask_processing_failed', 
                             target_issue_id: target_issue.id)
            add_error(error_text, template_issue.id)
            # ✅ ИЗМЕНЕНО: записываем ошибку в журнал шаблона с рассылкой уведомлений
            log_error_in_template_history(template_issue, error_text)
            return
          end
          @created_subtasks_count += subtasks_count
          calculate_single_issue_dates(target_issue, template_issue)
          check_subtask_chain_vs_parent_due(target_issue, template_issue)
        else
          calculate_single_issue_dates(target_issue, template_issue)
        end

        # Шаг 3.9: Логирование успешного создания
        subtask_message = has_subtasks ? 
           I18n.t('task_automation.log.with_subtasks', count: target_issue.children.count) : ''
        TaskAutomation::Service.log_message('info',
          I18n.t('task_automation.log.issue_created', 
                 issue_id: target_issue.id,
                 subject: target_issue.subject,
                 subtasks: subtask_message),
          template_issue.id)
        @created_issues_count += 1
        send_creation_notifications(target_issue, template_issue.id)

        # Шаг 3.10: Обновление даты следующего выполнения
        begin
          update_next_execution_date(template_issue, target_issue.id)
        rescue => e
          add_warning(I18n.t('task_automation.log.next_date_update_failed', error: e.message), template_issue.id)
        end

      rescue => e
        # ✅ ИЗМЕНЕНО: при исключении записываем ошибку в журнал шаблона
        # Используем специальный ключ без issue_id шаблона в тексте
        error_text_for_log = I18n.t('task_automation.log.template_processing_error', 
                                    issue_id: template_issue.id, 
                                    error: e.message)
        error_text_for_journal = I18n.t('task_automation.journal.error_template_processing', 
                                        error: e.message)
        add_error(error_text_for_log, template_issue.id)
        # ✅ ИЗМЕНЕНО: записываем ошибку в журнал шаблона с рассылкой уведомлений
        log_error_in_template_history(template_issue, error_text_for_journal)
      end
    end

    # ============================================================================
    # Проверка даты следующего выполнения относительно даты начала
    #
    # Если дата следующего выполнения (кастомное поле) раньше стандартного
    # поля «Дата начала» (start_date) шаблона, метод сдвигает дату следующего
    # выполнения вперёд, применяя интервал итеративно, пока она не станет
    # >= даты начала.
    #
    # Действия при корректировке:
    #   1. Запись WARNING в лог-файл плагина (без отправки администраторам).
    #   2. Обновление кастомного поля «Дата следующего выполнения» в шаблоне.
    #   3. Создание записи в журнале шаблона с уведомлением наблюдателей.
    #
    # Возвращает:
    #   true  — дата была скорректирована
    #   false — корректировка не потребовалась
    # ============================================================================
    def check_and_adjust_next_date_vs_start_date(template_issue, interval_unit)
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      interval_field_id = @custom_field_ids[FIELD_INTERVAL_VALUE]
      day_number_field_id = @custom_field_ids[FIELD_DAY_NUMBER]
      repeat_days_field_id = @custom_field_ids[FIELD_REPEAT_DAYS]
      month_field_id = @custom_field_ids[FIELD_MONTH]

      # Если нет поля даты следующего выполнения — нечего проверять
      return false unless date_field_id.present?

      # Получаем дату начала из стандартного поля шаблона
      start_date = template_issue.start_date
      # Если дата начала не задана — проверка не требуется
      return false unless start_date.present?

      # Получаем текущую дату следующего выполнения
      current_next_date = template_issue.custom_field_value(date_field_id)
      return false unless current_next_date.present?
      current_next_date = current_next_date.to_date

      # Если дата следующего выполнения >= даты начала — всё в порядке
      return false if current_next_date >= start_date

      # ================================================================
      # Дата следующего выполнения раньше даты начала — нужно сдвинуть.
      # Применяем интервал итеративно, пока new_date >= start_date.
      # ================================================================
      old_date = current_next_date.dup

      interval_value = interval_field_id.present? ?
                       (template_issue.custom_field_value(interval_field_id).to_i rescue 1) : 1

      new_date = current_next_date
      max_iterations = 1000
      iterations = 0

      # Цикл сдвига даты вперёд до тех пор, пока она не станет >= start_date
      while new_date < start_date && iterations < max_iterations
        new_date = case interval_unit
                   when 'год', 'year'
                     calculate_yearly_date(new_date, interval_value, template_issue,
                                          day_number_field_id, repeat_days_field_id,
                                          month_field_id, apply_interval: true)
                   when 'месяц', 'month'
                     calculate_monthly_date(new_date, interval_value, template_issue,
                                           day_number_field_id, repeat_days_field_id,
                                           apply_interval: true)
                   when 'неделя', 'week'
                     calculate_weekly_date(new_date, interval_value, template_issue,
                                          repeat_days_field_id, apply_interval: true)
                   when 'день', 'day'
                     calculate_daily_date(new_date, interval_value)
                   else
                     # По умолчанию — дневной интервал
                     calculate_daily_date(new_date, interval_value)
                   end
        iterations += 1
      end

      # Защита от бесконечного цикла (теоретически недостижимо, но для безопасности)
      if iterations >= max_iterations
        # Записываем WARNING только в лог-файл (без отправки администраторам)
        TaskAutomation::Service.log_message('warning',
          I18n.t('task_automation.validation.start_date_adjustment_max_iterations',
                 start_date: start_date.strftime('%Y-%m-%d')),
          template_issue.id)
        return false
      end

      # ================================================================
      # Обновляем кастомное поле «Дата следующего выполнения» в шаблоне
      # ================================================================
      template_issue.custom_field_values = { date_field_id => new_date }

      # ================================================================
      # Записываем WARNING в лог-файл плагина.
      # Используем Service.log_message напрямую (НЕ add_warning),
      # чтобы это сообщение НЕ попало в email администраторам.
      # ================================================================
      TaskAutomation::Service.log_message('warning',
        I18n.t('task_automation.validation.start_date_adjustment',
               old_date: old_date.strftime('%Y-%m-%d'),
               new_date: new_date.strftime('%Y-%m-%d'),
               start_date: start_date.strftime('%Y-%m-%d')),
        template_issue.id)

      # ================================================================
      # Создаём запись в журнале шаблона с уведомлением наблюдателей.
      # Метод сохраняет шаблон с notifications: true (по умолчанию),
      # поэтому наблюдатели получат стандартное уведомление Redmine
      # об изменении кастомного поля.
      # ================================================================
      log_date_adjustment_in_template_history(template_issue, old_date, new_date, start_date)

      # Возвращаем true — дата была скорректирована
      true
    end

    # ============================================================================
    # Запись корректировки даты в журнал задачи-шаблона
    #
    # Создаёт запись в журнале (Journal) шаблона с деталью изменения
    # кастомного поля «Дата следующего выполнения» (старое → новое значение).
    # Сохранение выполняется С уведомлениями (notifications: true),
    # чтобы наблюдатели шаблона получили стандартное email-уведомление
    # Redmine об изменении задачи.
    # ============================================================================
    def log_date_adjustment_in_template_history(template_issue, old_date, new_date, start_date)
      begin
        # Получаем пользователя, от имени которого ведётся журналирование
        user = User.find(@settings[:author_id])

        date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
        return unless date_field_id.present?

        # Формируем текст заметки для журнала
        journal_note = I18n.t('task_automation.journal.start_date_adjustment',
                              old_date: old_date.strftime('%Y-%m-%d'),
                              new_date: new_date.strftime('%Y-%m-%d'),
                              start_date: start_date.strftime('%Y-%m-%d'))

        # Инициализируем журнал с текстом заметки
        template_issue.init_journal(user, journal_note)

        # Добавляем деталь изменения кастомного поля (старое → новое значение)
        journal_detail = JournalDetail.new(
          property: 'cf',
          prop_key: date_field_id.to_s,
          old_value: format_date(old_date),
          value: format_date(new_date)
        )
        template_issue.current_journal.details << journal_detail

        # ================================================================
        # Сохраняем С уведомлениями (без notifications: false),
        # чтобы наблюдатели шаблона получили email об изменении.
        # Повторная попытка при StaleObjectError.
        # ================================================================
        max_retries = 3
        retry_count = 0
        begin
          template_issue.save!
        rescue ActiveRecord::StaleObjectError => e
          retry_count += 1
          if retry_count < max_retries
            template_issue.reload
            # После reload восстанавливаем кастомное поле и журнал
            template_issue.custom_field_values = { date_field_id => new_date }
            template_issue.init_journal(user, journal_note)
            template_issue.current_journal.details << JournalDetail.new(
              property: 'cf',
              prop_key: date_field_id.to_s,
              old_value: format_date(old_date),
              value: format_date(new_date)
            )
            retry
          else
            # Не прерываем выполнение — корректировка поля уже выполнена,
            # не удалось только записать в журнал
            Rails.logger.warn "[TaskAutomation] log_date_adjustment_in_template_history: " \
                              "не удалось записать в журнал шаблона " \
                              "##{template_issue.id} после #{max_retries} попыток"
          end
        end

      rescue => e
        # Ловим любые неожиданные ошибки, чтобы не прерывать обработку
        Rails.logger.error "[TaskAutomation] log_date_adjustment_in_template_history: " \
                           "ОШИБКА - #{e.class}: #{e.message}"
        Rails.logger.error "[TaskAutomation] log_date_adjustment_in_template_history: " \
                           "Backtrace: #{e.backtrace.first(5).join("\n")}"
      end
    end

    # ============================================================================
    # Извлечение понятного сообщения об ошибке валидации
    # ============================================================================
    def extract_validation_error_message(exception, target_project, assignee, template_issue_id)
      error_message = exception.message
      
      # ✅ Проверяем, связана ли ошибка с назначенным
      if error_message.include?('assigned_to') || error_message.include?('Назначен') || error_message.include?('Назначена')
        assignee_name = assignee.is_a?(User) ? assignee.name : assignee.is_a?(Group) ? assignee.name : assignee.to_s
        
        # ✅ Проверяем, является ли ошибка "пользователь не в проекте"
        if error_message.include?('неверное') || error_message.include?('invalid') || error_message.include?('недопустимое')
          return I18n.t('task_automation.log.issue_assignee_not_in_project',
                        assignee_name: assignee_name,
                        project_name: target_project.name)
        else
          return I18n.t('task_automation.log.issue_assignee_invalid',
                        assignee_name: assignee_name,
                        project_name: target_project.name)
        end
      end
      
      # ✅ Для остальных ошибок валидации — форматируем сообщение
      if error_message.include?('Validation failed')
        # Извлекаем имена полей и причины из ошибок
        fields_errors = []
        exception.record.errors.full_messages.each do |msg|
          fields_errors << msg
        end
        
        if fields_errors.any?
          attribute_name = exception.record.errors.attribute_names.first
          field_name = attribute_name.to_s.humanize
          return I18n.t('task_automation.log.issue_validation_failed',
                        field: field_name,
                        reason: fields_errors.first)
        end
      end
      
      # ✅ По умолчанию — возвращаем оригинальное сообщение
      I18n.t('task_automation.log.issue_save_error', error: error_message)
    end

    def parse_custom_fields_from_description(description)
      return { fields: {}, used_lines: [] } unless description.present?
      
      custom_fields = {}
      used_lines = []
      
      # ✅ НОВОЕ: Регулярное выражение для проверки формата кастомного поля
      # Формат: <название_поля>: <значение>
      # - название начинается с первого символа строки
      # - может содержать: буквы (русские/английские), цифры, пробелы, _, -
      # - после названия сразу двоеточие (без пробела)
      # - после двоеточия пробел
      # - после пробела значение
      custom_field_pattern = /^[A-Za-zА-Яа-яЁё0-9][A-Za-zА-Яа-яЁё0-9_\s-]*[A-Za-zА-Яа-яЁё0-9]:\s.+/
      
      description.lines.each do |line|
        # ✅ ПРОВЕРКА: Строка должна соответствовать шаблону кастомного поля
        next unless line.match?(custom_field_pattern)
        
        if line.include?(':')
          parts = line.split(':', 2)
          if parts.length == 2
            field_name = parts[0].strip
            field_value = parts[1].strip
            
            unless field_name.blank?
              custom_fields[field_name] = field_value
              used_lines << line.chomp  # Сохраняем оригинальную строку для удаления
            end
          end
        end
      end
      
      { fields: custom_fields, used_lines: used_lines }
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
      
      source_issue.attachments.each_with_index do |attachment, index|
        begin
          # Проверяем существование файла на диске
          unless File.exist?(attachment.diskfile)
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
          
          # Закрываем и удаляем временный файл
          temp_file.close
          temp_file.unlink
          
        rescue => e
          Rails.logger.error "[TaskAutomation] copy_attachments: Ошибка копирования - #{e.class}: #{e.message}"
          Rails.logger.error "[TaskAutomation] copy_attachments: Backtrace: #{e.backtrace.first(3).join("\n")}"
        end
      end
      
    end

    # ============================================================================
    # Добавление наблюдателей к задаче (устаревший метод, использовать calculate_watcher_ids + add_watchers_to_issue)
    # ============================================================================
    def add_watchers(target_issue, template_issue, assignee)
      # Для обратной совместимости
      watcher_ids = calculate_watcher_ids(template_issue, assignee)
      add_watchers_to_issue(target_issue, watcher_ids)
    end

    # ============================================================================
    # НОВЫЙ МЕТОД: Вычисление списка ID наблюдателей (один раз для всех задач)
    # ============================================================================
    def calculate_watcher_ids(template_issue, assignee)
      watcher_ids = []
      watcher_field_id = @custom_field_ids[FIELD_WATCHER_GROUPS]
      
      if watcher_field_id.present?
        watcher_search_string = template_issue.custom_field_value(watcher_field_id)
        
        if watcher_search_string.present?
          watcher_search_string.to_s.split(',').each do |watcher_fragment|
            watcher_fragment = watcher_fragment.strip
            next if watcher_fragment.blank?
            
            watcher = TaskAutomation::Service.find_user_or_group_by_name_fragment(watcher_fragment)
            
            if watcher
              watcher_ids << watcher.id
            else
              add_warning(I18n.t('task_automation.log.watcher_not_found', 
                               search_string: watcher_fragment), template_issue.id)
            end
          end
        end
      end
      
      # Исключаем assignee из watcher_ids
      if assignee.present?
        assignee_ids = []
        if assignee.is_a?(User)
          assignee_ids << assignee.id
        elsif assignee.is_a?(Group)
          assignee_ids << assignee.id
        end
        
        watcher_ids = watcher_ids - assignee_ids
      end
      
      watcher_ids
    end

    # ============================================================================
    # НОВЫЙ МЕТОД: Добавление наблюдателей к задаче (по готовому списку ID)
    # ============================================================================
    def add_watchers_to_issue(issue, watcher_ids)
      return if watcher_ids.empty?
      
      # ✅ ИСПРАВЛЕНО: Повторная попытка сохранения при StaleObjectError
      max_retries = 3
      retry_count = 0
      
      begin
        existing_watcher_ids = issue.watcher_user_ids
        issue.watcher_user_ids = (existing_watcher_ids + watcher_ids).uniq
        
        issue.save!(notifications: false)
        
      rescue ActiveRecord::StaleObjectError => e
        retry_count += 1
        
        if retry_count < max_retries
          issue.reload
          retry
        else
          # Не прерываем выполнение, это не критично
        end
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
        rescue => e
          Rails.logger.warn "[TaskAutomation] add_watcher_if_not_exists: ошибка создания Watcher - #{e.message}"
        end
      end
    end

    # ============================================================================
    # Расчет дат для задачи без подзадач (или для родительской задачи)
    # ============================================================================
    def calculate_single_issue_dates(issue, template_issue)
      
      duration_field_id = @custom_field_ids[FIELD_DURATION_DAYS]
      end_on_working_day_field_id = @custom_field_ids[FIELD_END_ON_WORKING_DAY]
      
      # Получение duration
      raw_duration = template_issue.custom_field_value(duration_field_id) if duration_field_id.present?
      
      duration = duration_field_id.present? ? 
                  (template_issue.custom_field_value(duration_field_id).to_i rescue 0) : 0
      
      
      end_on_working_day = end_on_working_day_field_id.present? && 
                          (template_issue.custom_field_value(end_on_working_day_field_id).to_i == 1)
      
      if duration == 0
        issue.due_date = issue.start_date
      else
        issue.due_date = issue.start_date + (duration - 1).days   #1 день - это завершение задачи в день начала
      end
      
      if end_on_working_day && issue.due_date.present? && !TaskAutomation::Service.working_day?(issue.due_date)
        adjusted_due_date = TaskAutomation::Service.shift_to_working_day(issue.due_date, direction: :backward)
        days_shift = (issue.due_date - adjusted_due_date).to_i
        issue.start_date = issue.start_date - days_shift.days
        issue.due_date = adjusted_due_date
      end
      
      # ✅ ИСПРАВЛЕНО: Повторная попытка сохранения при StaleObjectError
      max_retries = 3
      retry_count = 0
      
      begin
        # ✅ ВАЖНО: Сохраняем вычисленные даты перед reload
        calculated_due_date = issue.due_date
        calculated_start_date = issue.start_date
        
        # Reload для получения актуального lock_version
        issue.reload
        
        # ✅ ВОССТАНАВЛИВАЕМ вычисленные даты после reload
        issue.due_date = calculated_due_date
        issue.start_date = calculated_start_date

        issue.save!(notifications: false)

      rescue ActiveRecord::StaleObjectError => e
        retry_count += 1
        
        if retry_count < max_retries
          retry
        else
          add_error(I18n.t('task_automation.log.stale_object_error', 
                           issue_id: issue.id, 
                           retries: max_retries), template_issue.id)
          raise
        end
      end
    end

    # ============================================================================
    # Расчет даты завершения подзадачи
    # ОТЛИЧИЕ ОТ РОДИТЕЛЬСКОЙ: сдвиг ВПЕРЁД, start_date НЕ меняется
    # ============================================================================
    def calculate_subtask_due_date(subtask, subtask_template)
      duration_field_id = @custom_field_ids[FIELD_DURATION_DAYS]
      end_on_working_day_field_id = @custom_field_ids[FIELD_END_ON_WORKING_DAY]
      
      # Получаем длительность (обязательное поле, но добавляем защиту)
      duration = duration_field_id.present? ? 
                 (subtask_template.custom_field_value(duration_field_id).to_i rescue 0) : 0
      
      # Проверка: Конец в рабочий день
      end_on_working_day = end_on_working_day_field_id.present? && 
                          (subtask_template.custom_field_value(end_on_working_day_field_id).to_i == 1)
      
      # Устанавливаем due_date
      if duration == 0
        subtask.due_date = subtask.start_date
      else
        subtask.due_date = subtask.start_date + (duration - 1).days   #1 день - это завершение задачи в день начала
      end
      
      # КОРРЕКТИРОВКА: Если "Конец в рабочий день" = да и due_date на выходном
      # ✅ ДЛЯ ПОДЗАДАЧ: сдвигаем ВПЕРЁД (не назад как у основных задач)
      if end_on_working_day && subtask.due_date.present? && !TaskAutomation::Service.working_day?(subtask.due_date)
        
        # ✅ Сдвигаем ВПЕРЁД к ближайшему рабочему дню (для подзадач)
        adjusted_due_date = TaskAutomation::Service.shift_to_working_day(subtask.due_date, direction: :forward)
        
        # ✅ start_date НЕ меняем (только для подзадач)
        subtask.due_date = adjusted_due_date
      end
      
      # ✅ ИСПРАВЛЕНО: Повторная попытка сохранения при StaleObjectError
      max_retries = 3
      retry_count = 0
      
      begin
        # Сохраняем и перезагружаем для гарантии актуальных данных
        subtask.save!(notifications: false)
        subtask.reload
        
        # Гарантированный возврат даты (даже если что-то пошло не так)
        result_date = subtask.due_date || subtask.start_date
        
        result_date
        
      rescue ActiveRecord::StaleObjectError => e
        retry_count += 1
        
        if retry_count < max_retries
          subtask.reload
          retry
        else
          add_error(I18n.t('task_automation.log.stale_object_error', 
                           issue_id: subtask.id, 
                           retries: max_retries), subtask_template.id)
          nil
        end
      end
    end

    # ============================================================================
    # Обработка подзадач шаблона
    # ============================================================================
    def process_subtasks(template_issue, target_issue, target_project, assignment_group, watcher_ids = [])
      subtasks_created = 0
      subtasks = template_issue.children
      
      # ✅ УДАЛЕНО: unless target_issue.tracker.subtask?
      # Эта проверка некорректна - target_issue это родительская задача, она не может быть подзадачей
      # Проверка трекеров подзадач уже выполнена в validate_subtask_trackers ДО создания задачи
      
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
            group_start_date,
            watcher_ids
          )

          unless target_subtask
            return [false, 0]
          end
      
          subtasks_created += 1
          subtask_end_date = calculate_subtask_due_date(target_subtask, subtask_template)
          
          # due_date всегда есть (гарантировано методом calculate_subtask_due_date)
          if group_max_end.blank? || subtask_end_date > group_max_end
            group_max_end = subtask_end_date
          end
        end
        
        if max_end_date.blank? || group_max_end > max_end_date
          max_end_date = group_max_end
        end
        
        # ✅ Защита на случай nil (теоретически невозможно, но для безопасности)
        if group_max_end.present?
          current_start_date = group_max_end + 1.day
        else
          current_start_date = group_start_date + 1.day
        end
      end
      
      # ✅ Проверка - не вышла ли цепочка подзадач за пределы срока родителя
      if target_issue.due_date.present? && max_end_date.present?
        if max_end_date > target_issue.due_date
          days_overdue = (max_end_date - target_issue.due_date).to_i
          add_warning(
            I18n.t('task_automation.log.subtask_chain_exceeds_parent',
                   days: days_overdue,
                   parent_due: target_issue.due_date.strftime('%Y-%m-%d'),
                   subtask_chain_end: max_end_date.strftime('%Y-%m-%d')),
            template_issue.id
          )
        end
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

    # ============================================================================
    # ИЗМЕНЁННЫЙ МЕТОД: Обновление даты следующего выполнения
    # ============================================================================
    def update_next_execution_date(template_issue, target_issue_id = nil)
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
      old_date_value = current_date.dup
      
      interval_unit = unit_field_id.present? ? template_issue.custom_field_value(unit_field_id) : nil
      interval_value = interval_field_id.present? ? (template_issue.custom_field_value(interval_field_id).to_i rescue 1) : 1
      
      # Вычисляем новую дату С применением интервала
      new_date = case interval_unit
                 when 'год', 'year'
                   calculate_yearly_date(current_date, interval_value, template_issue, day_number_field_id, repeat_days_field_id, month_field_id, apply_interval: true)
                 when 'месяц', 'month'
                   calculate_monthly_date(current_date, interval_value, template_issue, day_number_field_id, repeat_days_field_id, apply_interval: true)
                 when 'неделя', 'week'
                   calculate_weekly_date(current_date, interval_value, template_issue, repeat_days_field_id, apply_interval: true)
                 when 'день', 'day'
                   calculate_daily_date(current_date, interval_value)
                 else
                   calculate_daily_date(current_date, interval_value)
                 end
      
      if new_date.present?
        template_issue.custom_field_values = { date_field_id => new_date }
        
        # Журналирование ПЕРЕД сохранением
        if target_issue_id.present?
          log_task_creation_in_template_history(template_issue, target_issue_id, old_date_value, new_date)
        else
          template_issue.save!(notifications: false)
        end
      end
    end

    # ============================================================================
    # ИЗМЕНЁННЫЙ МЕТОД: calculate_yearly_date (универсальный)
    # ============================================================================
    def calculate_yearly_date(current_date, interval, template_issue, day_number_field_id, repeat_days_field_id, month_field_id, apply_interval: true)
      begin
        month_field_value = month_field_id.present? ? 
                            template_issue.custom_field_value(month_field_id) : nil
        day_number_raw = day_number_field_id.present? ? 
                        template_issue.custom_field_value(day_number_field_id) : nil
        repeat_days_raw = repeat_days_field_id.present? ? 
                         template_issue.custom_field_value(repeat_days_field_id) : nil
        
        day_number = day_number_raw.present? ? day_number_raw.to_i : nil
        repeat_days_array = parse_repeat_days(repeat_days_raw)
        
        target_year = apply_interval ? (current_date.year + interval) : current_date.year
        month_num = month_field_value.present? ? month_name_to_number(month_field_value) : current_date.month
        
        # СЛУЧАЙ 1: Поля не заполнены → простая дата
        if day_number.blank? && repeat_days_array.empty?
          max_day = Date.new(target_year, month_num, -1).day
          target_day = [current_date.day, max_day].min
          return Date.new(target_year, month_num, target_day)
        end
        
        # СЛУЧАЙ 2: Номер + Дни повторения + Месяц
        if day_number.present? && repeat_days_array.any?
          day_num = repeat_day_name_to_number(repeat_days_array.first)
          
          if day_number == 5
            new_date = find_last_weekday_in_month(target_year, month_num, day_num)
          else
            new_date = find_nth_weekday_in_month(target_year, month_num, day_num, day_number)
          end
          
          return new_date if new_date
        end
        
        # Запасной вариант
        apply_interval ? (current_date + interval.years) : current_date
        
      rescue => e
        add_warning(I18n.t('task_automation.log.date_calculation_error', error: e.message), template_issue.id)
        apply_interval ? (current_date + interval.years) : current_date
      end
    end

    # ============================================================================
    # ИЗМЕНЁННЫЙ МЕТОД: calculate_monthly_date (универсальный)
    # ============================================================================
    def calculate_monthly_date(current_date, interval, template_issue, day_number_field_id, repeat_days_field_id, apply_interval: true)
      begin
        day_number_raw = day_number_field_id.present? ? 
                        template_issue.custom_field_value(day_number_field_id) : nil
        repeat_days_raw = repeat_days_field_id.present? ? 
                         template_issue.custom_field_value(repeat_days_field_id) : nil
        
        day_number = day_number_raw.present? ? day_number_raw.to_i : nil
        repeat_days_array = parse_repeat_days(repeat_days_raw)
        
        # Расчет целевого месяца
        if apply_interval
          target_month = current_date.month + interval
          target_year = current_date.year
          
          while target_month > 12
            target_month -= 12
            target_year += 1
          end
        else
          # НЕ применяем интервал - остаемся в том же месяце
          target_month = current_date.month
          target_year = current_date.year
        end
        
        # СЛУЧАЙ 1: Поля не заполнены → простое число месяца
        if day_number.blank? && repeat_days_array.empty?
          max_day = Date.new(target_year, target_month, -1).day
          target_day = [current_date.day, max_day].min
          return Date.new(target_year, target_month, target_day)
        end
        
        # СЛУЧАЙ 2: Номер + Дни повторения заполнены
        if day_number.present? && repeat_days_array.any?
          day_num = repeat_day_name_to_number(repeat_days_array.first)
          
          if day_number == 5
            new_date = find_last_weekday_in_month(target_year, target_month, day_num)
          else
            new_date = find_nth_weekday_in_month(target_year, target_month, day_num, day_number)
          end
          
          return new_date if new_date
        end
        
        # Запасной вариант
        apply_interval ? (current_date >> interval) : current_date
        
      rescue => e
        add_warning(I18n.t('task_automation.log.date_calculation_error', error: e.message), template_issue.id)
        apply_interval ? (current_date >> interval) : current_date
      end
    end

    # ============================================================================
    # ИЗМЕНЁННЫЙ МЕТОД: calculate_weekly_date (универсальный)
    # apply_interval: true  → штатный расчет следующей даты (после создания задачи)
    # apply_interval: false → проверка соответствия (без применения интервала)
    # ============================================================================
    def calculate_weekly_date(current_date, interval, template_issue, repeat_days_field_id, apply_interval: true)
      begin
        repeat_days_raw = repeat_days_field_id.present? ? 
                           template_issue.custom_field_value(repeat_days_field_id) : nil
        
        repeat_days_array = parse_repeat_days(repeat_days_raw)
        
        if repeat_days_array.empty?
          return apply_interval ? (current_date + interval.weeks) : current_date
        end
        
        today = Date.today
        
        if repeat_days_array.length == 1
          # ОДИН день
          day_num = repeat_day_name_to_number(repeat_days_array.first)
          
          if apply_interval
            # ШТАТНЫЙ РАСЧЕТ: применяем интервал
            base_date = current_date >= today ? current_date : today
            new_date = base_date + interval.weeks
            while new_date.wday != day_num
              new_date += 1.day
            end
          else
            # ПРОВЕРКА: НЕ применяем интервал, ищем ближайший этот день
            new_date = current_date
            while new_date.wday != day_num
              new_date += 1.day
            end
          end
        else 
          # НЕСКОЛЬКО дней - ищем следующий из списка
          weekdays = repeat_days_array.map { |d| repeat_day_name_to_number(d) }
          
          if apply_interval
            # ✅ ПОСЛЕ СОЗДАНИЯ ЗАДАЧИ: ищем следующий день ПОСЛЕ current_date
            # Даже если сегодня подходящий день - всё равно идём дальше
            new_date = current_date + 1.day
            
            while !weekdays.include?(new_date.wday)
              new_date += 1.day
            end
          else
            # ✅ ПРИ ПРОВЕРКЕ: ищем начиная с current_date (включительно)
            # Если сегодня подходящий день - оставляем как есть
            new_date = current_date
            
            while !weekdays.include?(new_date.wday)
              new_date += 1.day
            end
          end
        end
        
        new_date
      rescue => e
        add_warning(I18n.t('task_automation.log.date_calculation_error', error: e.message), template_issue.id)
        apply_interval ? (current_date + interval.weeks) : current_date
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
                 subtasks: @created_subtasks_count,
                 errors: @error_templates_count))
      else
        TaskAutomation::Service.log_message('info',
          I18n.t('task_automation.log.summary_no_tasks',
          errors: @error_templates_count))
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
          
          # Используем встроенный метод Redmine
          Mailer.deliver_issue_add(issue)
          
          TaskAutomation::Service.log_message('info',
            I18n.t('task_automation.log.notifications_sent', issue_id: issue.id),
            issue.id)
        end
      rescue => e
        add_warning(I18n.t('task_automation.log.notification_error', 
                           error: e.message), template_issue_id)
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

    # ============================================================================
    # Метод журналирования создания задачи в истории шаблона
    # Создает запись в истории задачи-шаблона о создании целевой задачи
    # ============================================================================
    def log_task_creation_in_template_history(template_issue, target_issue_id, old_next_date, new_next_date)
      begin
        
        # Получаем пользователя для журналирования
        user = User.find(@settings[:author_id])
        
        # Инициализируем журнал для задачи-шаблона
        if target_issue_id.present?
          template_issue.init_journal(user, I18n.t('task_automation.journal.task_created', issue_id: target_issue_id))
        else
          # Если target_issue_id пустой, создаем журнал без заметки (только для изменения даты)
          template_issue.init_journal(user, " ")
        end

        # Получаем ID кастомного поля "Дата следующего выполнения"
        date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
        
        unless date_field_id.present?
          return
        end
        
        # Добавляем деталь изменения кастомного поля
        journal_detail = JournalDetail.new(
          property: 'cf',
          prop_key: date_field_id.to_s,
          old_value: old_next_date.present? ? format_date(old_next_date.to_date) : nil,
          value: new_next_date.present? ? format_date(new_next_date.to_date) : nil
        )
        
        template_issue.current_journal.details << journal_detail
        
        # ✅ ИСПРАВЛЕНО: Повторная попытка сохранения при StaleObjectError
        max_retries = 3
        retry_count = 0
        
        begin
          template_issue.save!(notifications: false)
        rescue ActiveRecord::StaleObjectError => e
          retry_count += 1
          
          if retry_count < max_retries
            template_issue.reload
            retry
          else
            add_warning(I18n.t('task_automation.log.stale_object_warning', 
                          issue_id: template_issue.id,
                          retries: max_retries), template_issue.id)
            # Не прерываем выполнение, это не критично
          end
        end
        
        last_journal = template_issue.journals.order(:id => :desc).first
        
      rescue => e
        Rails.logger.error "[TaskAutomation] log_task_creation_in_template_history: ОШИБКА - #{e.class}: #{e.message}"
        Rails.logger.error "[TaskAutomation] log_task_creation_in_template_history: Backtrace: #{e.backtrace.first(5).join("\n")}"
      end
    end

    # ============================================================================
    # НОВЫЙ МЕТОД: Запись ошибки в журнал задачи-шаблона с рассылкой уведомлений
    # В отличие от log_task_creation_in_template_history, здесь:
    # - текст ошибки НЕ содержит номера задачи-шаблона
    # - сохранение выполняется С уведомлениями (наблюдатели шаблона получат email)
    # ============================================================================
    def log_error_in_template_history(template_issue, error_message)
      begin
        # Получаем пользователя, от имени которого ведётся журналирование
        user = User.find(@settings[:author_id])
        # Инициализируем журнал с текстом ошибки (без номера шаблона)
        template_issue.init_journal(user, error_message)
        max_retries = 3
        retry_count = 0
        begin
          template_issue.save!
        rescue ActiveRecord::StaleObjectError => e
          retry_count += 1
          if retry_count < max_retries
            template_issue.reload
            # Повторно инициализируем журнал после reload (он сбрасывается)
            template_issue.init_journal(user, error_message)
            retry
          else
            # Не прерываем выполнение — это не критично для основной логики
            Rails.logger.warn "[TaskAutomation] log_error_in_template_history: " \
                              "не удалось записать ошибку в журнал шаблона " \
                              "##{template_issue.id} после #{max_retries} попыток"
          end
        end
      rescue => e
        # Ловим любые неожиданные ошибки, чтобы не прерывать обработку
        Rails.logger.error "[TaskAutomation] log_error_in_template_history: " \
                           "ОШИБКА - #{e.class}: #{e.message}"
        Rails.logger.error "[TaskAutomation] log_error_in_template_history: " \
                           "Backtrace: #{e.backtrace.first(5).join("\n")}"
      end
    end

    # ============================================================================
    # Вспомогательный метод форматирования даты
    # ============================================================================
    def format_date(date)
      return nil unless date.present?
      date.is_a?(String) ? date : date.strftime('%Y-%m-%d')
    end

    # ============================================================================
    # НОВЫЙ МЕТОД: Валидация дополнительных полей периодичности
    # ============================================================================
    def validate_additional_fields(template_issue, interval_unit)
      errors = []
      warnings = []
      
      day_number_field_id = @custom_field_ids[FIELD_DAY_NUMBER]
      repeat_days_field_id = @custom_field_ids[FIELD_REPEAT_DAYS]
      month_field_id = @custom_field_ids[FIELD_MONTH]
      interval_field_id = @custom_field_ids[FIELD_INTERVAL_VALUE]
      
      # Получаем значения полей
      day_number_raw = day_number_field_id.present? ? 
                       template_issue.custom_field_value(day_number_field_id) : nil
      repeat_days_raw = repeat_days_field_id.present? ? 
                        template_issue.custom_field_value(repeat_days_field_id) : nil
      month_value = month_field_id.present? ? 
                    template_issue.custom_field_value(month_field_id) : nil
      interval_value = interval_field_id.present? ? 
                       (template_issue.custom_field_value(interval_field_id).to_i rescue 1) : 1
      
      # Конвертируем repeat_days в массив
      repeat_days_array = parse_repeat_days(repeat_days_raw)
      day_number = day_number_raw.present? ? day_number_raw.to_i : nil
      
      case interval_unit
      when 'день', 'day'
        # Для интервала "день" дополнительные поля игнорируются
        if day_number.present? || repeat_days_array.any? || month_value.present?
          warnings << I18n.t('task_automation.validation.day_interval_extra_fields_warning')
        end
        
      when 'неделя', 'week'
        # Для интервала "неделя" с несколькими днями интервал игнорируется
        if repeat_days_array.length > 1 && interval_value > 1
          warnings << I18n.t('task_automation.validation.week_multiple_days_interval_warning')
        end
        
      when 'месяц', 'month'
        # Поля "Номер" и "Дни повторения" должны быть оба заполнены или оба пустые
        day_number_filled = day_number.present?
        repeat_days_filled = repeat_days_array.any?
        
        if day_number_filled != repeat_days_filled
          errors << I18n.t('task_automation.validation.month_both_fields_required')
        end
        
        # Если оба заполнены, проверяем валидность
        if day_number_filled && repeat_days_filled
          # Номер должен быть от 1 до 5
          unless day_number >= 1 && day_number <= 5
            errors << I18n.t('task_automation.validation.month_day_number_invalid')
          end
          
          # Дни повторения - только одно значение
          if repeat_days_array.length > 1
            errors << I18n.t('task_automation.validation.month_multiple_repeat_days')
          end
        end
        
      when 'год', 'year'
        # Те же правила как для месяца
        day_number_filled = day_number.present?
        repeat_days_filled = repeat_days_array.any?
        
        if day_number_filled != repeat_days_filled
          errors << I18n.t('task_automation.validation.month_both_fields_required')
        end
        
        # Если поля заполнены, поле "Месяц" обязательно
        if (day_number_filled || repeat_days_filled) && month_value.blank?
          errors << I18n.t('task_automation.validation.year_month_required')
        end
        
        if day_number_filled && repeat_days_filled
          unless day_number >= 1 && day_number <= 5
            errors << I18n.t('task_automation.validation.month_day_number_invalid')
          end
          
          if repeat_days_array.length > 1
            errors << I18n.t('task_automation.validation.month_multiple_repeat_days')
          end
        end
      end
      
      { valid: errors.empty?, errors: errors, warnings: warnings }
    end

    # ============================================================================
    # НОВЫЙ МЕТОД: Парсинг поля "Дни повторения" в массив
    # ============================================================================
    def parse_repeat_days(repeat_days_raw)
      return [] unless repeat_days_raw.present?
      
      case repeat_days_raw
      when Array
        repeat_days_raw.compact.reject(&:blank?)
      when String
        begin
          parsed = JSON.parse(repeat_days_raw)
          if parsed.is_a?(Array)
            parsed.compact.reject(&:blank?)
          else
            repeat_days_raw.split(/[;,]/).map(&:strip).reject(&:blank?)
          end
        rescue JSON::ParserError
          repeat_days_raw.split(/[;,]/).map(&:strip).reject(&:blank?)
        end
      else
        []
      end
    end

    # ============================================================================
    # ИЗМЕНЁННЫЙ МЕТОД: Проверка соответствия даты расписанию
    # ============================================================================
    def check_date_matches_schedule(template_issue, interval_unit)
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      interval_field_id = @custom_field_ids[FIELD_INTERVAL_VALUE]
      day_number_field_id = @custom_field_ids[FIELD_DAY_NUMBER]
      repeat_days_field_id = @custom_field_ids[FIELD_REPEAT_DAYS]
      month_field_id = @custom_field_ids[FIELD_MONTH]
      
      current_date = template_issue.custom_field_value(date_field_id)
      return { matches: true, next_valid_date: nil } unless current_date.present?
      
      current_date = current_date.to_date
      interval_value = interval_field_id.present? ? 
                       (template_issue.custom_field_value(interval_field_id).to_i rescue 1) : 1
      
      today = Date.today
      
      # Вычисляем ожидаемую дату БЕЗ применения интервала
      expected_date = case interval_unit
                      when 'день', 'day'
                        current_date
                      when 'неделя', 'week'
                        # ✅ ИСПРАВЛЕНО: используем calculate_weekly_date с apply_interval: false
                        calculate_weekly_date(current_date, interval_value, template_issue, 
                                             repeat_days_field_id, apply_interval: false)
                      when 'месяц', 'month'
                        # ✅ ИСПРАВЛЕНО: используем calculate_monthly_date с apply_interval: false
                        calculate_monthly_date(current_date, interval_value, template_issue,
                                              day_number_field_id, repeat_days_field_id,
                                              apply_interval: false)
                      when 'год', 'year'
                        # ✅ ИСПРАВЛЕНО: используем calculate_yearly_date с apply_interval: false
                        calculate_yearly_date(current_date, interval_value, template_issue,
                                             day_number_field_id, repeat_days_field_id,
                                             month_field_id, apply_interval: false)
                      else
                        current_date
                      end
      
      if expected_date != current_date
        return { matches: false, next_valid_date: expected_date }
      end

      { matches: true, next_valid_date: nil }
    end

    # ============================================================================
    # ИЗМЕНЁННЫЙ МЕТОД: Найти N-ный день недели в месяце
    # occurrence = 1-4 → первая, вторая, третья, четвертая
    # occurrence = 5 → последняя
    # ============================================================================
    def find_nth_weekday_in_month(year, month, weekday_num, occurrence = 1)
      if occurrence == 5
        # Последний день недели в месяце
        return find_last_weekday_in_month(year, month, weekday_num)
      end
      
      date = Date.new(year, month, 1)
      count = 0
      
      while date.month == month
        if date.wday == weekday_num
          count += 1
          return date if count >= occurrence
        end
        date += 1.day
      end
      
      nil
    end

    # ============================================================================
    # НОВЫЙ МЕТОД: Найти последний день недели в месяце
    # ============================================================================
    def find_last_weekday_in_month(year, month, weekday_num)
      # Начинаем с последнего дня месяца и идём назад
      last_day = Date.new(year, month, -1)
      date = last_day
      
      while date.month == month
        if date.wday == weekday_num
          return date
        end
        date -= 1.day
      end
      
      nil
    end

    # ============================================================================
    # Обновление даты следующего выполнения на указанную
    # ============================================================================
    def update_next_execution_date_to(template_issue, new_date)
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      return unless date_field_id.present? && new_date.present?
      
      template_issue.custom_field_values = { date_field_id => new_date }
      
      # ✅ ИСПРАВЛЕНО: Повторная попытка сохранения при StaleObjectError
      max_retries = 3
      retry_count = 0
      
      begin
        template_issue.save!(notifications: false)
      rescue ActiveRecord::StaleObjectError => e
        retry_count += 1
        
        if retry_count < max_retries
          template_issue.reload
          retry
        else
          add_warning(I18n.t('task_automation.log.stale_object_warning', 
                            issue_id: template_issue.id, 
                            retries: max_retries), template_issue.id)
          # Не прерываем выполнение
        end
      end
    end

    # ============================================================================
    # НОВЫЙ МЕТОД: Проверка - не вышла ли цепочка подзадач за пределы срока родителя
    # Вызывается ПОСЛЕ расчета due_date родителя
    # ============================================================================
    def check_subtask_chain_vs_parent_due(target_issue, template_issue)
      subtasks = template_issue.children
      return unless subtasks.any?
      
      # Находим максимальную due_date среди всех подзадач
      # Для этого нужно перезагрузить target_issue и получить актуальные подзадачи
      target_issue.reload
      actual_subtasks = target_issue.children
      
      max_subtask_due = actual_subtasks.map(&:due_date).compact.max
      
      if max_subtask_due.present? && target_issue.due_date.present?
        if max_subtask_due > target_issue.due_date
          days_overdue = (max_subtask_due - target_issue.due_date).to_i
          add_warning(
            I18n.t('task_automation.log.subtask_chain_exceeds_parent',
                   days: days_overdue,
                   parent_due: target_issue.due_date.strftime('%Y-%m-%d'),
                   subtask_chain_end: max_subtask_due.strftime('%Y-%m-%d')),
            template_issue.id
          )
        end
      end
    end

    # ============================================================================
    # Метод установки категории
    # ============================================================================
    def set_category_field(issue, field_value, template_issue_id)
      return unless field_value.present?
      
      # ✅ Ищем категорию ТОЛЬКО в текущем проекте
      category = IssueCategory.find_by(project: issue.project, name: field_value)
      
      unless category
        add_warning(I18n.t('task_automation.log.standard_field_not_found', 
                           field_name: 'Категория', 
                           field_value: field_value), template_issue_id)
        return
      end
      
      unless issue.tracker.core_fields.include?('category_id')
        add_warning(I18n.t('task_automation.log.standard_field_not_available', 
                           field_name: 'Категория', 
                           tracker_name: issue.tracker.name), template_issue_id)
        return
      end
      
      issue.category = category
    end

    # ============================================================================
    # Метод установки версии
    # ============================================================================
    def set_version_field(issue, field_value, template_issue_id)
      return unless field_value.present?
      
      # ✅ Ищем версию ТОЛЬКО в текущем проекте
      version = issue.project.shared_versions.find_by(name: field_value)
      
      unless version
        add_warning(I18n.t('task_automation.log.standard_field_not_found', 
                           field_name: 'Версия', 
                           field_value: field_value), template_issue_id)
        return
      end
      
      unless issue.tracker.core_fields.include?('fixed_version_id')
        add_warning(I18n.t('task_automation.log.standard_field_not_available', 
                           field_name: 'Версия', 
                           tracker_name: issue.tracker.name), template_issue_id)
        return
      end
      
      issue.fixed_version = version
    end

    # ============================================================================
    # Метод установки оценки временных затрат
    # ============================================================================
    def set_estimated_hours_field(issue, field_value, template_issue_id)
      return unless field_value.present?
      
      estimated_hours = field_value.to_f
      
      unless estimated_hours > 0
        add_warning(I18n.t('task_automation.log.standard_field_invalid_value', 
                           field_name: 'Оценка временных затрат', 
                           field_value: field_value), template_issue_id)
        return
      end
      
      unless issue.tracker.core_fields.include?('estimated_hours')
        add_warning(I18n.t('task_automation.log.standard_field_not_available', 
                           field_name: 'Оценка временных затрат', 
                           tracker_name: issue.tracker.name), template_issue_id)
        return
      end
      
      issue.estimated_hours = estimated_hours
    end

    # ============================================================================
    # Метод установки готовности (в процентах)
    # ============================================================================
    def set_done_ratio_field(issue, field_value, template_issue_id)
      return unless field_value.present?
      
      # Удаляем символ % если есть и преобразуем в число
      done_ratio = field_value.to_s.gsub('%', '').strip.to_i
      
      unless done_ratio >= 0 && done_ratio <= 100
        add_warning(I18n.t('task_automation.log.standard_field_invalid_value', 
                           field_name: 'Готовность', 
                           field_value: field_value), template_issue_id)
        return
      end
      
      unless issue.tracker.core_fields.include?('done_ratio')
        add_warning(I18n.t('task_automation.log.standard_field_not_available', 
                           field_name: 'Готовность', 
                           tracker_name: issue.tracker.name), template_issue_id)
        return
      end
      
      issue.done_ratio = done_ratio
    end

    # ============================================================================
    # Метод установки приоритета
    # ============================================================================
    def set_priority_field(issue, field_value, template_issue_id)
      return unless field_value.present?
      
      # ✅ Ищем по имени среди активных IssuePriority
      priority = IssuePriority.active.find_by(name: field_value)
      
      unless priority
        add_warning(I18n.t('task_automation.log.standard_field_not_found', 
                           field_name: 'Приоритет', 
                           field_value: field_value), template_issue_id)
        return
      end
      
      # Проверяем доступность поля для трекера
      unless issue.tracker.core_fields.include?('priority_id')
        add_warning(I18n.t('task_automation.log.standard_field_not_available', 
                           field_name: 'Приоритет', 
                           tracker_name: issue.tracker.name), template_issue_id)
        return
      end
      
      issue.priority = priority
    end

    # ============================================================================
    # Создание целевой задачи
    # ============================================================================
    def create_target_issue(template_issue, target_project, target_tracker, assignee)
      issue = nil
      
      ActiveRecord::Base.transaction do
        issue = Issue.new
        issue.project = target_project
        issue.tracker = target_tracker
        issue.author = User.find(@settings[:author_id])
        issue.subject = template_issue.subject
        
        # 1. Парсим описание шаблона
        parse_result = parse_custom_fields_from_description(template_issue.description)
        raw_fields = parse_result[:fields]
        raw_used_lines = parse_result[:used_lines]
        
        # 2. Применяем поля к новой задаче и получаем список реально использованных строк
        #    (используются только те поля, которые есть в проекте и трекере)
        final_used_lines = apply_fields_to_issue(issue, raw_fields, raw_used_lines, template_issue.id)
        
        # 3. Удаляем из описания только те строки, которые реально были применены
        remaining_lines = template_issue.description.lines.reject { |line| final_used_lines.include?(line.chomp) }
        issue.description = remaining_lines.join
        
        issue.status = target_tracker.default_status
        issue.priority = IssuePriority.default
        
        # Дата начала = дате следующего выполнения из шаблона
        date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
        next_date = template_issue.custom_field_value(date_field_id)
        issue.start_date = next_date.to_date if next_date.present?
        
        issue.assigned_to = assignee
        issue.notify = false
        
        # Первое сохранение
        issue.save!
        
        # Копирование вложений
        copy_attachments(template_issue, issue)
      end
      
      issue.reload if issue.persisted?
      issue
    rescue ActiveRecord::RecordInvalid => e
      error_message = extract_validation_error_message(e, target_project, assignee, template_issue.id) 
      add_error(error_message, template_issue.id)
      log_error_in_template_history(template_issue, error_message)
      nil
    rescue => e
      add_error(I18n.t('task_automation.log.issue_save_error', error: e.message), template_issue.id)
      log_error_in_template_history(template_issue, I18n.t('task_automation.log.issue_save_error', error: e.message))
      nil
    end

    # ============================================================================
    # Создание подзадачи
    # ============================================================================
    def create_target_subtask(subtask_template, parent_issue, target_project, assignment_group, start_date, watcher_ids = [])
      subtask = Issue.new
      subtask.project = target_project 
      # Получаем трекер подзадачи
      tracker_field_id = @custom_field_ids[FIELD_TARGET_TRACKER]
      tracker_name = subtask_template.custom_field_value(tracker_field_id) if tracker_field_id.present?
      subtask_tracker = TaskAutomation::Service.get_target_tracker_by_name(
        tracker_name, target_project, @custom_field_ids)
      unless subtask_tracker
        error_text = I18n.t('task_automation.log.subtask_tracker_not_found')
        add_error(error_text, subtask_template.id)
        log_error_in_template_history(subtask_template, error_text)
        return nil
      end
      subtask.tracker = subtask_tracker
      subtask.parent_id = parent_issue.id
      subtask.author = User.find(@settings[:author_id])
      subtask.subject = subtask_template.subject
      # 1. Парсим описание
      parse_result = parse_custom_fields_from_description(subtask_template.description)
      raw_fields = parse_result[:fields]
      raw_used_lines = parse_result[:used_lines]
      # 2. Применяем поля (с проверкой наличия в проекте/трекере)
      final_used_lines = apply_fields_to_issue(subtask, raw_fields, raw_used_lines, subtask_template.id)
      # 3. Чистим описание
      remaining_lines = subtask_template.description.lines.reject { |line| final_used_lines.include?(line.chomp) }
      subtask.description = remaining_lines.join
      subtask.start_date = start_date
      subtask.assigned_to = assignment_group
      subtask.status = subtask_tracker.default_status
      # Сохранение подзадачи
      max_retries = 3
      retry_count = 0
      begin
        subtask.save!(notifications: false)
        if watcher_ids.any?
          add_watchers_to_issue(subtask, watcher_ids)
        end
        copy_attachments(subtask_template, subtask)
        subtask
      rescue ActiveRecord::StaleObjectError => e
        retry_count += 1
        if retry_count < max_retries
          retry
        else
          error_text = I18n.t('task_automation.log.stale_object_error', issue_id: subtask.id, retries: max_retries)
          add_error(error_text, subtask_template.id) 
          log_error_in_template_history(subtask_template, error_text)
          nil
        end
      rescue => e
        error_text = I18n.t('task_automation.log.subtask_save_error', error: e.message)
        add_error(error_text, subtask_template.id)
        log_error_in_template_history(subtask_template, error_text)
        nil
      end
    end

    # ============================================================================
    # Применение полей к задаче с проверкой доступности
    # Возвращает массив строк, которые БЫЛИ успешно применены (для удаления из описания)
    # ============================================================================
    def apply_fields_to_issue(issue, fields_hash, used_lines, template_issue_id)
      successfully_applied_lines = []
      
      # Получаем список доступных кастомных полей (пересечение проекта и трекера)
      available_cf_names = issue.available_custom_fields.map(&:name)
      
      fields_hash.each do |field_name, field_value|
        original_line = used_lines.find { |line| line.start_with?("#{field_name}:") }
        next unless original_line
        
        # 1. Проверяем, является ли поле стандартным
        standard_attr = TaskAutomation::Configuration::STANDARD_FIELDS_MAPPING[field_name]
        
        if standard_attr
          # Проверяем, включено ли стандартное поле в трекере
          if issue.tracker.core_fields.include?(standard_attr.to_s)
            set_standard_field_by_attr(issue, standard_attr, field_value, template_issue_id)
            successfully_applied_lines << original_line
          else
            # Поле не включено в трекер -> не удаляем строку из описания
            add_warning(I18n.t('task_automation.log.field_not_in_tracker', field_name: field_name), template_issue_id)
          end
        else
          # 2. Если не стандартное, проверяем кастомное
          if available_cf_names.include?(field_name)
            # Поле доступно (есть и в проекте, и в трекере)
            custom_field = issue.available_custom_fields.find { |cf| cf.name == field_name }
            
            # Пробуем установить значение
            begin
              issue.custom_field_values = { custom_field.id => field_value }
              successfully_applied_lines << original_line
            rescue => e
              add_warning(I18n.t('task_automation.log.field_set_error', field_name: field_name, error: e.message), template_issue_id)
            end
          else
            # Поля нет в проекте или трекере -> не удаляем строку из описания
            # Это ключевое изменение логики
          end
        end
      end
      
      successfully_applied_lines
    end

    # ============================================================================
    # Установка стандартного поля по атрибуту
    # ============================================================================
    def set_standard_field_by_attr(issue, attr_symbol, value, template_issue_id)
      case attr_symbol
      when :category_id
        set_category_field(issue, value, template_issue_id)
      when :fixed_version_id
        set_version_field(issue, value, template_issue_id)
      when :estimated_hours
        set_estimated_hours_field(issue, value, template_issue_id)
      when :done_ratio
        set_done_ratio_field(issue, value, template_issue_id)
      when :priority_id
        set_priority_field(issue, value, template_issue_id)
      end
    end

    # ============================================================================
    # Проверка и предупреждение о пропущенных обязательных полях
    # Метод удалён, т.к. при создании задачи, если поле обязательное,
    # то при попытке сохранить Redmine сам выдаст соответствующие ошибки.
    # ============================================================================
    # def check_and_warn_missing_required_fields(issue, template_issue_id)

    # ============================================================================
    # Парсинг полей из описания
    # ============================================================================
    def parse_custom_fields_from_description(description)
      return { fields: {}, used_lines: [] } unless description.present?
      
      custom_fields = {}
      used_lines = []
      
      # Регулярное выражение для проверки формата кастомного поля
      custom_field_pattern = /^[A-Za-zА-Яа-яЁё0-9][A-Za-zА-Яа-яЁё0-9_\s-]*[A-Za-zА-Яа-яЁё0-9]:\s.+/
      
      description.lines.each do |line|
        next unless line.match?(custom_field_pattern)
        
        if line.include?(':')
          parts = line.split(':', 2)
          if parts.length == 2
            field_name = parts[0].strip
            field_value = parts[1].strip
            
            unless field_name.blank?
              custom_fields[field_name] = field_value
              used_lines << line.chomp
            end
          end
        end
      end
      
      { fields: custom_fields, used_lines: used_lines }
    end

  end
end