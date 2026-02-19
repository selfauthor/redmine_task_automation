# ============================================================================
# Файл: lib/task_automation/task_processor.rb
# Назначение: Основной процессор бизнес-логики для автоматизации задач
# ============================================================================

module TaskAutomation
  class TaskProcessor
    # ============================================================================
    # Подключение модуля конфигурации для доступа к константам
    # ============================================================================
    include TaskAutomation::Configuration
    
    # ============================================================================
    # Инициализация процессора
    # ============================================================================
    def initialize
      # Инициализация массива для хранения сообщений об ошибках
      @errors = []
      
      # Инициализация массива для хранения информационных сообщений
      @messages = []
      
      # Счётчик созданных основных задач
      @created_issues_count = 0
      
      # Счётчик созданных подзадач
      @created_subtasks_count = 0
      
      # Получение настроек плагина через модель TaskAutomation
      @settings = TaskAutomation.get_settings
      
      # Хэш для кэширования ID кастомных полей (избегает повторных запросов к БД)
      @custom_field_ids = {}
      
      # Инициализация кэша полей через метод конфигурации
      initialize_custom_field_cache
    end
    
    # ============================================================================
    # Основной метод обработки всех задач-шаблонов
    # ============================================================================
    def process
      # Логирование начала процесса обработки
      TaskAutomation.log_message('info', I18n.t('task_automation.log.processing_started'))
      
      # Проверка валидности настроек плагина
      unless validate_settings
        # Логирование ошибки валидации настроек
        TaskAutomation.log_message('error', I18n.t('task_automation.log.settings_invalid'))
        # Возврат результата с ошибкой
        return build_result(false)
      end
      
      # Поиск всех задач-шаблонов, требующих обработки
      template_issues = find_template_issues
      
      # Проверка наличия задач для обработки
      if template_issues.empty?
        # Логирование отсутствия задач
        TaskAutomation.log_message('info', I18n.t('task_automation.log.no_templates_found'))
        # Возврат результата без ошибок
        return build_result(true)
      end
      
      # Обработка каждой найденной задачи-шаблона
      template_issues.each do |template_issue|
        # Обработка отдельной задачи-шаблона с обработкой исключений
        begin
          process_template_issue(template_issue)
        rescue => e
          # Логирование непредвиденной ошибки обработки
          TaskAutomation.log_message('error', 
            I18n.t('task_automation.log.template_processing_error', 
                   issue_id: template_issue.id, 
                   error: e.message))
          # Добавление ошибки в массив
          @errors << I18n.t('task_automation.log.template_processing_error', 
                           issue_id: template_issue.id, 
                           error: e.message)
        end
      end
      
      # Логирование итогов обработки
      log_summary
      
      # Построение и возврат результата выполнения
      build_result(@errors.empty?)
    end
    
    # ============================================================================
    # Метод проверки валидности настроек плагина
    # ============================================================================
    def validate_settings
      # Проверка наличия ID проекта с шаблонами
      if @settings[:source_project_id].blank?
        @errors << I18n.t('task_automation.validation.source_project_required')
        return false
      end
      
      # Проверка существования проекта с шаблонами
      unless TaskAutomation.project_exists?(@settings[:source_project_id])
        @errors << I18n.t('task_automation.validation.source_project_not_found')
        return false
      end
      
      # Проверка наличия ID автора задач
      if @settings[:author_id].blank?
        @errors << I18n.t('task_automation.validation.author_required')
        return false
      end
      
      # Проверка существования пользователя-автора
      unless User.exists?(@settings[:author_id])
        @errors << I18n.t('task_automation.validation.author_not_found')
        return false
      end
      
      # Проверка наличия ID трекера
      if @settings[:tracker_id].blank?
        @errors << I18n.t('task_automation.validation.tracker_required')
        return false
      end
      
      # Возврат true, если все проверки пройдены
      true
    end
    
    # ============================================================================
    # Метод инициализации кэша ID кастомных полей
    # Использует константы из Configuration
    # ============================================================================
    def initialize_custom_field_cache
      # Перебор всех необходимых полей из конфигурации
      TaskAutomation::Configuration::REQUIRED_CUSTOM_FIELDS.each do |field_name|
        # Получение ID каждого поля и сохранение в кэш
        @custom_field_ids[field_name] = TaskAutomation.get_custom_field_id_by_name(field_name)
      end
    end
    
    # ============================================================================
    # Метод поиска задач-шаблонов для обработки
    # Использует константы из Configuration
    # ============================================================================
    def find_template_issues
      # Получение ID поля с датой следующего выполнения из кэша
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      
      # Проверка наличия поля даты
      if date_field_id.blank?
        @errors << I18n.t('task_automation.validation.date_field_not_found')
        return []
      end
      
      # Получение ID поля с количеством дней заблаговременного создания
      ahead_days_field_id = @custom_field_ids[FIELD_CREATE_AHEAD_DAYS]
      
      # Формирование сегодняшней даты
      today = Date.today
      
      # Запрос к базе данных для поиска задач-шаблонов
      Issue.where(
        project_id: @settings[:source_project_id],
        tracker_id: @settings[:tracker_id]
      ).select do |issue|
        # Получение значения поля даты следующего выполнения
        next_date = issue.custom_field_value(date_field_id)
        
        # Получение значения поля дней заблаговременности
        ahead_days = ahead_days_field_id.present? ? 
                     (issue.custom_field_value(ahead_days_field_id).to_i rescue 0) : 0
        
        # Проверка условия: дата выполнения - дни заблаговременности <= сегодня
        next_date.present? && (next_date.to_date - ahead_days.days) <= today
      end
    end
    
    # ============================================================================
    # Метод обработки отдельной задачи-шаблона
    # ============================================================================
    def process_template_issue(template_issue)
      # Логирование начала обработки шаблона
      TaskAutomation.log_message('info', 
        I18n.t('task_automation.log.processing_template', issue_id: template_issue.id),
        template_issue.id)
      
      # Переменная для хранения созданной целевой задачи
      target_issue = nil
      
      # ========================================================================
      # Шаг 3.1: Проверка проекта назначения
      # ========================================================================
      target_project = get_target_project(template_issue)
      
      # Если проект не найден, запись ошибки и переход к следующей задаче
      unless target_project
        TaskAutomation.log_message('error',
          I18n.t('task_automation.log.project_not_found'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.project_not_found')
        return
      end
      
      # ========================================================================
      # Шаг 3.2: Проверка трекера
      # ========================================================================
      target_tracker = get_target_tracker(template_issue, target_project)
      
      # Если трекер не найден, запись ошибки и переход к следующей задаче
      unless target_tracker
        TaskAutomation.log_message('error',
          I18n.t('task_automation.log.tracker_not_found'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.tracker_not_found')
        return
      end
      
      # ========================================================================
      # Шаг 3.3: Проверка группы назначения
      # ========================================================================
      assignment_group = get_assignment_group(template_issue)
      
      # Если группа не найдена или не может быть назначена, запись ошибки
      unless assignment_group && TaskAutomation.group_can_be_assigned?(assignment_group.name, target_project.id)
        TaskAutomation.log_message('error',
          I18n.t('task_automation.log.group_not_found'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.group_not_found')
        return
      end
      
      # ========================================================================
      # Шаг 3.4-3.6: Создание целевой задачи
      # ========================================================================
      target_issue = create_target_issue(template_issue, target_project, target_tracker, assignment_group)
      
      # Если создание задачи не удалось, запись ошибки
      unless target_issue
        TaskAutomation.log_message('error',
          I18n.t('task_automation.log.issue_creation_failed'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.issue_creation_failed')
        return
      end
      
      # ========================================================================
      # Шаг 3.7: Добавление наблюдателей
      # ========================================================================
      add_watchers(target_issue, template_issue, assignment_group)
      
      # ========================================================================
      # Шаг 3.8: Обработка подзадач
      # ========================================================================
      has_subtasks = template_issue.children.any?
      
      if has_subtasks
        # Обработка подзадач, если они есть
        success, subtasks_count = process_subtasks(template_issue, target_issue, target_project, assignment_group)
        
        # Если обработка подзадач не удалась, удаление созданной задачи
        unless success
          target_issue.destroy
          TaskAutomation.log_message('error',
            I18n.t('task_automation.log.subtask_processing_failed'),
            template_issue.id)
          @errors << I18n.t('task_automation.log.subtask_processing_failed')
          return
        end
        
        # Обновление счётчика подзадач
        @created_subtasks_count += subtasks_count
        
        # Расчёт срока выполнения родительской задачи на основе подзадач
        calculate_parent_due_date(target_issue, template_issue)
      else
        # ====================================================================
        # Шаг 3.8.1: Расчёт срока выполнения без подзадач
        # ====================================================================
        calculate_single_issue_dates(target_issue, template_issue)
      end
      
      # ========================================================================
      # Шаг 3.9: Логирование успешного создания задачи
      # ========================================================================
      subtask_message = has_subtasks ? 
        I18n.t('task_automation.log.with_subtasks', count: target_issue.children.count) : ''
      
      TaskAutomation.log_message('info',
        I18n.t('task_automation.log.issue_created', 
               issue_id: target_issue.id,
               subject: target_issue.subject,
               subtasks: subtask_message),
        target_issue.id)
      
      # Увеличение счётчика созданных задач
      @created_issues_count += 1
      
      # ========================================================================
      # Шаг 3.10: Обновление даты следующего выполнения в шаблоне
      # ========================================================================
      update_next_execution_date(template_issue)
    end
    
    # ============================================================================
    # Метод получения проекта назначения из кастомного поля шаблона
    # ============================================================================
    def get_target_project(template_issue)
      # Получение ID поля проекта назначения из константы
      project_field_id = @custom_field_ids[FIELD_TARGET_PROJECT]
      
      # Возврат nil, если поле не настроено
      return nil unless project_field_id.present?
      
      # Получение значения поля (ID проекта)
      project_id = template_issue.custom_field_value(project_field_id).to_i
      
      # Проверка существования проекта
      return nil unless TaskAutomation.project_exists?(project_id)
      
      # Возврат объекта проекта
      Project.find(project_id)
    end
    
    # ============================================================================
    # Метод получения трекера назначения из кастомного поля шаблона
    # ============================================================================
    def get_target_tracker(template_issue, target_project)
      # Получение ID поля трекера из константы
      tracker_field_id = @custom_field_ids[FIELD_TARGET_TRACKER]
      
      # Возврат nil, если поле не настроено
      return nil unless tracker_field_id.present?
      
      # Получение значения поля (название трекера)
      tracker_name = template_issue.custom_field_value(tracker_field_id)
      
      # Возврат nil, если название пустое
      return nil unless tracker_name.present?
      
      # Поиск трекера по имени в рамках проекта
      tracker = Tracker.find_by(name: tracker_name)
      
      # Проверка наличия трекера в проекте
      return nil unless tracker && target_project.trackers.include?(tracker)
      
      # Возврат объекта трекера
      tracker
    end
    
    # ============================================================================
    # Метод получения группы назначения из кастомного поля шаблона
    # ============================================================================
    def get_assignment_group(template_issue)
      # Получение ID поля группы назначения из константы
      group_field_id = @custom_field_ids[FIELD_ASSIGNMENT_GROUP]
      
      # Возврат nil, если поле не настроено
      return nil unless group_field_id.present?
      
      # Получение названия группы из поля
      group_name = template_issue.custom_field_value(group_field_id)
      
      # Возврат nil, если название пустое
      return nil unless group_name.present?
      
      # Поиск и возврат группы по имени
      TaskAutomation.get_group_by_name(group_name)
    end
    
    # ============================================================================
    # Метод создания целевой задачи на основе шаблона
    # ============================================================================
    def create_target_issue(template_issue, target_project, target_tracker, assignment_group)
      # Создание нового объекта задачи
      issue = Issue.new
      
      # Установка проекта
      issue.project = target_project
      
      # Установка трекера
      issue.tracker = target_tracker
      
      # Установка автора (пользователь из настроек)
      issue.author = User.find(@settings[:author_id])
      
      # Установка темы (копируется из шаблона)
      issue.subject = template_issue.subject
      
      # Установка описания (копируется из шаблона)
      issue.description = template_issue.description
      
      # Установка статуса по умолчанию для трекера
      issue.status = target_tracker.default_status
      
      # Установка приоритета по умолчанию
      issue.priority = IssuePriority.default
      
      # Установка даты начала (сегодня)
      issue.start_date = Date.today
      
      # Назначение на группу
      issue.assigned_to = assignment_group
      
      # ========================================================================
      # Обработка дополнительных полей из описания
      # ========================================================================
      custom_fields_from_description = parse_custom_fields_from_description(template_issue.description)
      
      # Заполнение кастомных полей
      unless custom_fields_from_description.empty?
        set_custom_fields(issue, custom_fields_from_description, template_issue.id)
      end
      
      # Сохранение задачи с валидацией
      issue.save!(notifications: false)
      
      # ========================================================================
      # Перенос вложенных файлов из шаблона
      # ========================================================================
      copy_attachments(template_issue, issue)
      
      # Повторное сохранение после добавления вложений
      issue.save!(notifications: false)
      
      # Возврат созданной задачи
      issue
    rescue => e
      # Логирование ошибки создания задачи
      TaskAutomation.log_message('error',
        I18n.t('task_automation.log.issue_save_error', error: e.message),
        template_issue.id)
      # Возврат nil при ошибке
      nil
    end
    
    # ============================================================================
    # Метод парсинга кастомных полей из описания задачи
    # ============================================================================
    def parse_custom_fields_from_description(description)
      # Возврат пустого хэша, если описание пустое
      return {} unless description.present?
      
      # Хэш для хранения найденных полей
      custom_fields = {}
      
      # Разделение описания на строки
      description.lines.each do |line|
        # Поиск строки с разделителем ":"
        if line.include?(':')
          # Разделение строки на название и значение
          parts = line.split(':', 2)
          
          # Проверка наличия обеих частей
          if parts.length == 2
            # Очистка от пробелов и служебных символов
            field_name = parts[0].strip
            field_value = parts[1].strip
            
            # Сохранение в хэш, если название не пустое
            custom_fields[field_name] = field_value unless field_name.blank?
          end
        end
      end
      
      # Возврат хэша с найденными полями
      custom_fields
    end
    
    # ============================================================================
    # Метод установки кастомных полей задачи
    # ============================================================================
    def set_custom_fields(issue, custom_fields_hash, template_issue_id)
      # Перебор всех указанных полей
      custom_fields_hash.each do |field_name, field_value|
        # Поиск ID кастомного поля по имени
        field_id = TaskAutomation.get_custom_field_id_by_name(field_name)
        
        # Если поле не найдено, запись предупреждения в журнал
        unless field_id.present?
          TaskAutomation.log_message('warning',
            I18n.t('task_automation.log.field_not_found', field_name: field_name),
            template_issue_id)
          @errors << I18n.t('task_automation.log.field_not_found', field_name: field_name)
          next
        end
        
        # Получение объекта кастомного поля
        custom_field = CustomField.find_by(id: field_id)
        
        # Проверка, что поле доступно для данного трекера
        unless custom_field && custom_field.trackers.include?(issue.tracker)
          TaskAutomation.log_message('warning',
            I18n.t('task_automation.log.field_not_available', field_name: field_name),
            template_issue_id)
          next
        end
        
        # Установка значения поля
        issue.custom_field_values = { field_id => field_value }
      end
      
      # Проверка обязательных полей трекера
      check_required_fields(issue, template_issue_id)
    end
    
    # ============================================================================
    # Метод проверки обязательных полей трекера
    # ============================================================================
    def check_required_fields(issue, template_issue_id)
      # Перебор всех кастомных полей трекера
      issue.tracker.custom_fields.each do |custom_field|
        # Проверка, является ли поле обязательным
        if custom_field.is_required
          # Проверка наличия значения
          if issue.custom_field_value(custom_field.id).blank?
            # Запись ошибки об отсутствии обязательного поля
            TaskAutomation.log_message('error',
              I18n.t('task_automation.log.required_field_missing', field_name: custom_field.name),
              template_issue_id)
            @errors << I18n.t('task_automation.log.required_field_missing', field_name: custom_field.name)
          end
        end
      end
    end
    
    # ============================================================================
    # Метод копирования вложений из одной задачи в другую
    # ============================================================================
    def copy_attachments(source_issue, target_issue)
      # Проверка наличия вложений у исходной задачи
      return unless source_issue.attachments.any?
      
      # Перебор всех вложений
      source_issue.attachments.each do |attachment|
        # Создание копии вложения для целевой задачи
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
    
    # ============================================================================
    # Метод добавления наблюдателей к задаче
    # ============================================================================
    def add_watchers(target_issue, template_issue, assignment_group)
      # ========================================================================
      # Получение групп наблюдателей из кастомного поля
      # ========================================================================
      watcher_field_id = @custom_field_ids[FIELD_WATCHER_GROUPS]
      
      if watcher_field_id.present?
        # Получение значения поля (список групп через разделитель)
        watcher_groups = template_issue.custom_field_value(watcher_field_id)
        
        if watcher_groups.present?
          # Разделение списка групп
          watcher_groups.split(/[;,]/).each do |group_name|
            # Очистка названия группы
            group_name = group_name.strip
            
            # Поиск группы
            group = TaskAutomation.get_group_by_name(group_name)
            
            # Добавление пользователей группы как наблюдателей
            if group
              group.users.each do |user|
                target_issue.watcher_users << user unless target_issue.watcher_users.include?(user)
              end
            end
          end
        end
      end
      
      # ========================================================================
      # Добавление группы исполнителей как наблюдателей (в любом случае)
      # ========================================================================
      assignment_group.users.each do |user|
        target_issue.watcher_users << user unless target_issue.watcher_users.include?(user)
      end
    end
    
    # ============================================================================
    # Метод обработки подзадач шаблона
    # ============================================================================
    def process_subtasks(template_issue, target_issue, target_project, assignment_group)
      # Счётчик успешно созданных подзадач
      subtasks_created = 0
      
      # Получение всех подзадач шаблона
      subtasks = template_issue.children
      
      # Проверка, поддерживает ли трекер создание подзадач
      unless target_issue.tracker.subtask?
        TaskAutomation.log_message('error',
          I18n.t('task_automation.log.tracker_no_subtasks'),
          template_issue.id)
        @errors << I18n.t('task_automation.log.tracker_no_subtasks')
        return [false, 0]
      end
      
      # Сортировка подзадач по порядковому номеру
      sorted_subtasks = sort_subtasks_by_order(subtasks)
      
      # Переменная для отслеживания даты начала следующей подзадачи
      current_start_date = target_issue.start_date
      
      # Переменная для отслеживания максимальной даты окончания параллельных задач
      max_end_date = nil
      
      # Группировка подзадач по порядковому номеру (параллельные имеют одинаковый номер)
      grouped_subtasks = sorted_subtasks.group_by { |st| get_subtask_order(st) }
      
      # Обработка каждой группы подзадач
      grouped_subtasks.each do |order, group_subtasks|
        # Дата начала для этой группы
        group_start_date = current_start_date
        
        # Переменная для максимальной даты окончания в группе
        group_max_end = nil
        
        # Обработка каждой подзадачи в группе
        group_subtasks.each do |subtask_template|
          # Создание целевой подзадачи
          target_subtask = create_target_subtask(
            subtask_template, 
            target_issue, 
            target_project, 
            assignment_group,
            group_start_date
          )
          
          # Если создание не удалось, возврат ошибки
          unless target_subtask
            return [false, 0]
          end
      
          # Увеличение счётчика
          subtasks_created += 1
          
          # Расчёт даты окончания подзадачи
          subtask_end_date = calculate_subtask_due_date(target_subtask, subtask_template)
          
          # Обновление максимальной даты окончания в группе
          if group_max_end.blank? || subtask_end_date > group_max_end
            group_max_end = subtask_end_date
          end
        end
        
        # Обновление глобальной максимальной даты окончания
        if max_end_date.blank? || group_max_end > max_end_date
          max_end_date = group_max_end
        end
        
        # Дата начала следующей группы = следующий день после максимальной даты окончания
        current_start_date = group_max_end + 1.day
      end
      
      # Возврат успешного результата и количества созданных подзадач
      [true, subtasks_created]
    end
    
    # ============================================================================
    # Метод сортировки подзадач по порядковому номеру
    # ============================================================================
    def sort_subtasks_by_order(subtasks)
      # Получение ID поля порядкового номера из константы
      order_field_id = @custom_field_ids[FIELD_SUBTASK_ORDER]
      
      # Если поле не настроено, возврат как есть
      return subtasks.to_a unless order_field_id.present?
      
      # Сортировка по значению поля
      subtasks.sort_by do |subtask|
        # Получение значения поля порядкового номера
        order_value = subtask.custom_field_value(order_field_id).to_i
        # Возврат значения для сортировки
        order_value
      end
    end
    
    # ============================================================================
    # Метод получения порядкового номера подзадачи
    # ============================================================================
    def get_subtask_order(subtask)
      # Получение ID поля порядкового номера из константы
      order_field_id = @custom_field_ids[FIELD_SUBTASK_ORDER]
      
      # Возврат 0, если поле не настроено
      return 0 unless order_field_id.present?
      
      # Получение и возврат значения
      subtask.custom_field_value(order_field_id).to_i
    end
    
    # ============================================================================
    # Метод создания целевой подзадачи
    # ============================================================================
    def create_target_subtask(subtask_template, parent_issue, target_project, assignment_group, start_date)
      # Создание нового объекта подзадачи
      subtask = Issue.new
      
      # Установка проекта
      subtask.project = target_project
      
      # Получение трекера подзадачи из шаблона
      subtask_tracker = get_target_tracker(subtask_template, target_project)
      
      # Если трекер не найден, запись ошибки
      unless subtask_tracker
        TaskAutomation.log_message('error',
          I18n.t('task_automation.log.subtask_tracker_not_found'),
          subtask_template.id)
        @errors << I18n.t('task_automation.log.subtask_tracker_not_found')
        return nil
      end
      
      # Установка трекера
      subtask.tracker = subtask_tracker
      
      # Установка родительской задачи
      subtask.parent_issue = parent_issue
      
      # Установка автора
      subtask.author = User.find(@settings[:author_id])
      
      # Установка темы
      subtask.subject = subtask_template.subject
      
      # Установка описания
      subtask.description = subtask_template.description
      
      # Установка даты начала
      subtask.start_date = start_date
      
      # Назначение на группу
      subtask.assigned_to = assignment_group
      
      # Установка статуса по умолчанию
      subtask.status = subtask_tracker.default_status
      
      # Обработка кастомных полей из описания
      custom_fields = parse_custom_fields_from_description(subtask_template.description)
      unless custom_fields.empty?
        set_custom_fields(subtask, custom_fields, subtask_template.id)
      end
      
      # Сохранение подзадачи
      subtask.save!(notifications: false)
      
      # Копирование вложений
      copy_attachments(subtask_template, subtask)
      
      # Повторное сохранение
      subtask.save!(notifications: false)
      
      # Возврат созданной подзадачи
      subtask
    rescue => e
      # Логирование ошибки
      TaskAutomation.log_message('error',
        I18n.t('task_automation.log.subtask_save_error', error: e.message),
        subtask_template.id)
      nil
    end
    
    # ============================================================================
    # Метод расчёта срока выполнения для задачи без подзадач
    # ============================================================================
    def calculate_single_issue_dates(issue, template_issue)
      # Получение ID поля срока выполнения из константы
      duration_field_id = @custom_field_ids[FIELD_DURATION_DAYS]
      
      # Получение ID поля "только рабочие дни" из константы
      working_days_field_id = @custom_field_ids[FIELD_WORKING_DAYS_ONLY]
      
      # Получение значения срока выполнения
      duration = duration_field_id.present? ? 
                 (template_issue.custom_field_value(duration_field_id).to_i rescue 0) : 0
      
      # Получение флага рабочих дней
      working_days_only = working_days_field_id.present? && 
                         (template_issue.custom_field_value(working_days_field_id).to_i == 1)
      
      # Расчёт даты окончания
      if duration == 0
        # Если срок 0, дата окончания = дата начала
        issue.due_date = issue.start_date
      elsif working_days_only
        # Если только рабочие дни, сдвиг на рабочие дни
        due_date = issue.start_date
        duration.times { due_date = TaskAutomation.shift_to_working_day(due_date + 1.day, direction: :forward) }
        issue.due_date = due_date
      else
        # Обычный расчёт по календарным дням
        issue.due_date = issue.start_date + duration.days
      end
      
      # Сохранение задачи
      issue.save!(notifications: false)
    end
    
    # ============================================================================
    # Метод расчёта срока выполнения подзадачи
    # ============================================================================
    def calculate_subtask_due_date(subtask, subtask_template)
      # Получение ID поля срока выполнения из константы
      duration_field_id = @custom_field_ids[FIELD_DURATION_DAYS]
      
      # Получение ID поля "только рабочие дни" из константы
      working_days_field_id = @custom_field_ids[FIELD_WORKING_DAYS_ONLY]
      
      # Получение значения срока
      duration = duration_field_id.present? ? 
                 (subtask_template.custom_field_value(duration_field_id).to_i rescue 0) : 0
      
      # Получение флага рабочих дней
      working_days_only = working_days_field_id.present? && 
                         (subtask_template.custom_field_value(working_days_field_id).to_i == 1)
      
      # Расчёт даты окончания
      if duration == 0
        subtask.due_date = subtask.start_date
      elsif working_days_only
        due_date = subtask.start_date
        duration.times { due_date = TaskAutomation.shift_to_working_day(due_date + 1.day, direction: :forward) }
        subtask.due_date = due_date
      else
        subtask.due_date = subtask.start_date + duration.days
      end
      
      # Сохранение
      subtask.save!(notifications: false)
      
      # Возврат даты окончания
      subtask.due_date
    end
    
    # ============================================================================
    # Метод расчёта срока выполнения родительской задачи на основе подзадач
    # ============================================================================
    def calculate_parent_due_date(parent_issue, template_issue)
      # Получение всех подзадач
      subtasks = parent_issue.children
      
      # Если подзадач нет, возврат
      return if subtasks.empty?
      
      # Поиск максимальной даты окончания среди подзадач
      max_due_date = subtasks.map(&:due_date).compact.max
      
      # Установка даты окончания родительской задачи
      if max_due_date.present?
        parent_issue.due_date = max_due_date
        parent_issue.save!(notifications: false)
      end
    end
    
    # ============================================================================
    # Метод обновления даты следующего выполнения в шаблоне
    # ============================================================================
    def update_next_execution_date(template_issue)
      # Получение ID необходимых полей из констант
      date_field_id = @custom_field_ids[FIELD_NEXT_EXECUTION_DATE]
      unit_field_id = @custom_field_ids[FIELD_INTERVAL_UNIT]
      interval_field_id = @custom_field_ids[FIELD_INTERVAL_VALUE]
      day_number_field_id = @custom_field_ids[FIELD_DAY_NUMBER]
      repeat_days_field_id = @custom_field_ids[FIELD_REPEAT_DAYS]
      month_field_id = @custom_field_ids[FIELD_MONTH]
      
      # Проверка наличия поля даты
      return unless date_field_id.present?
      
      # Получение текущей даты следующего выполнения
      current_date = template_issue.custom_field_value(date_field_id)
      return unless current_date.present?
      
      current_date = current_date.to_date
      
      # Получение единицы интервала
      interval_unit = unit_field_id.present? ? 
                     template_issue.custom_field_value(unit_field_id) : nil
      
      # Получение значения интервала
      interval_value = interval_field_id.present? ? 
                      (template_issue.custom_field_value(interval_field_id).to_i rescue 1) : 1
      
      # Переменная для новой даты
      new_date = nil
      
      # ========================================================================
      # Расчёт новой даты в зависимости от единицы интервала
      # ========================================================================
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
        # Интервал по умолчанию - дни
        new_date = calculate_daily_date(current_date, interval_value)
      end
      
      # Обновление значения поля, если дата рассчитана
      if new_date.present?
        template_issue.custom_field_values = { date_field_id => new_date }
        template_issue.save!(notifications: false)
      end
    end
    
    # ============================================================================
    # Вспомогательные методы расчёта дат (без изменений, используют константы)
    # ============================================================================
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
              TaskAutomation.log_message('error',
                I18n.t('task_automation.log.invalid_weekday_in_month'),
                template_issue.id)
              return current_date + interval.years
            end
          elsif day_number.present?
            new_date = Date.new(current_date.year + interval, month_num, day_number)
          else
            TaskAutomation.log_message('error',
              I18n.t('task_automation.log.month_without_day'),
              template_issue.id)
            return current_date + interval.years
          end
        else
          new_date = current_date + interval.years
        end
        
        new_date
      rescue => e
        TaskAutomation.log_message('error',
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
            TaskAutomation.log_message('error',
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
        TaskAutomation.log_message('error',
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
          TaskAutomation.log_message('error',
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
        TaskAutomation.log_message('error',
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
    
    # ============================================================================
    # Метод логирования итогов обработки
    # ============================================================================
    def log_summary
      if @created_issues_count > 0
        TaskAutomation.log_message('info',
          I18n.t('task_automation.log.summary_success', 
                 issues: @created_issues_count,
                 subtasks: @created_subtasks_count))
      else
        TaskAutomation.log_message('info',
          I18n.t('task_automation.log.summary_no_tasks'))
      end
    end
    
    # ============================================================================
    # Метод построения результата выполнения
    # ============================================================================
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
    
    # ============================================================================
    # Метод проверки наличия ошибок
    # ============================================================================
    def has_errors?
      @errors.any?
    end
  end
end