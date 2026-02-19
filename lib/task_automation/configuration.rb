# ============================================================================
# Файл: lib/task_automation/configuration.rb
# Назначение: Централизованное хранилище конфигурации и констант плагина
# ============================================================================

module TaskAutomation
  # ============================================================================
  # Модуль конфигурации - все константы в одном месте
  # ============================================================================
  module Configuration
    # ========================================================================
    # Названия кастомных полей (используются для поиска по имени)
    # Изменять только здесь - используется во всём плагине
    # ========================================================================
    
    # Поля для основной логики поиска и создания задач
    FIELD_NEXT_EXECUTION_DATE = 'Дата следующего выполнения'
    FIELD_CREATE_AHEAD_DAYS = 'Создать заранее'
    FIELD_TARGET_PROJECT = 'Проект назначения'
    FIELD_TARGET_TRACKER = 'Трекер'
    FIELD_ASSIGNMENT_GROUP = 'Назначение'
    FIELD_WATCHER_GROUPS = 'Наблюдатели'
    FIELD_DURATION_DAYS = 'Срок выполнения'
    FIELD_WORKING_DAYS_ONLY = 'Только рабочие дни'
    
    # Поля для расчёта интервалов повторения
    FIELD_INTERVAL_UNIT = 'Единица интервала'
    FIELD_INTERVAL_VALUE = 'Интервал'
    FIELD_DAY_NUMBER = 'Число'
    FIELD_REPEAT_DAYS = 'Дни повторения'
    FIELD_MONTH = 'Месяц'
    
    # Поля для подзадач
    FIELD_SUBTASK_ORDER = 'Порядковый номер'
    
    # ========================================================================
    # Массив всех необходимых кастомных полей для валидации
    # Используется в контроллере и Rake-задачах для проверки
    # ========================================================================
    REQUIRED_CUSTOM_FIELDS = [
      FIELD_NEXT_EXECUTION_DATE,
      FIELD_CREATE_AHEAD_DAYS,
      FIELD_TARGET_PROJECT,
      FIELD_TARGET_TRACKER,
      FIELD_ASSIGNMENT_GROUP,
      FIELD_WATCHER_GROUPS,
      FIELD_DURATION_DAYS,
      FIELD_WORKING_DAYS_ONLY,
      FIELD_INTERVAL_UNIT,
      FIELD_INTERVAL_VALUE,
      FIELD_DAY_NUMBER,
      FIELD_REPEAT_DAYS,
      FIELD_MONTH,
      FIELD_SUBTASK_ORDER
    ].freeze
    
    # ========================================================================
    # Настройки плагина по умолчанию
    # ========================================================================
    DEFAULT_SETTINGS = {
      'source_project_id' => '',
      'author_id' => '',
      'tracker_id' => '',
      'error_notification_email' => ''
    }.freeze
    
    # ========================================================================
    # Путь к файлу журнала логирования
    # ========================================================================
    LOG_FILE_PATH = Rails.root.join('log', 'task_automation.log').to_s
    
    # ========================================================================
    # Максимальный размер файла журнала перед ротацией (10 MB)
    # ========================================================================
    LOG_MAX_SIZE = 10 * 1024 * 1024
    
    # ========================================================================
    # Метод для получения всех полей сгруппированных по назначению
    # Возвращает хэш для удобного доступа
    # ========================================================================
    def self.fields_by_category
      {
        main: [
          FIELD_NEXT_EXECUTION_DATE,
          FIELD_CREATE_AHEAD_DAYS,
          FIELD_TARGET_PROJECT,
          FIELD_TARGET_TRACKER,
          FIELD_ASSIGNMENT_GROUP,
          FIELD_WATCHER_GROUPS
        ],
        timing: [
          FIELD_DURATION_DAYS,
          FIELD_WORKING_DAYS_ONLY,
          FIELD_INTERVAL_UNIT,
          FIELD_INTERVAL_VALUE
        ],
        recurrence: [
          FIELD_DAY_NUMBER,
          FIELD_REPEAT_DAYS,
          FIELD_MONTH
        ],
        subtasks: [
          FIELD_SUBTASK_ORDER
        ]
      }
    end
    
    # ========================================================================
    # Метод для проверки, является ли поле обязательным
    # ========================================================================
    def self.required_field?(field_name)
      REQUIRED_CUSTOM_FIELDS.include?(field_name)
    end
    
    # ========================================================================
    # Метод для получения описания поля (для отображения в интерфейсе)
    # ========================================================================
    def self.field_description(field_name)
      descriptions = {
        FIELD_NEXT_EXECUTION_DATE => 'Дата следующего выполнения задачи',
        FIELD_CREATE_AHEAD_DAYS => 'Количество дней для заблаговременного создания',
        FIELD_TARGET_PROJECT => 'Проект, в который будет создана задача',
        FIELD_TARGET_TRACKER => 'Трекер для создаваемой задачи',
        FIELD_ASSIGNMENT_GROUP => 'Группа пользователей для назначения задачи',
        FIELD_WATCHER_GROUPS => 'Группы наблюдателей для задачи',
        FIELD_DURATION_DAYS => 'Срок выполнения задачи в днях',
        FIELD_WORKING_DAYS_ONLY => 'Учитывать только рабочие дни',
        FIELD_INTERVAL_UNIT => 'Единица измерения интервала повторения',
        FIELD_INTERVAL_VALUE => 'Числовое значение интервала',
        FIELD_DAY_NUMBER => 'Число месяца или порядковый номер',
        FIELD_REPEAT_DAYS => 'Дни недели для повторения',
        FIELD_MONTH => 'Месяц для годового повторения',
        FIELD_SUBTASK_ORDER => 'Порядковый номер подзадачи'
      }
      
      descriptions[field_name] || 'Неизвестное поле'
    end
  end
end