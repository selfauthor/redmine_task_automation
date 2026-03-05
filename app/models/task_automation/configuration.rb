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
    # ========================================================================
    FIELD_NEXT_EXECUTION_DATE = 'Дата следующего выполнения'
    FIELD_CREATE_AHEAD_DAYS = 'Создать заранее'
    FIELD_TARGET_PROJECT = 'Проект назначения'
    FIELD_TARGET_TRACKER = 'Трекер'
    FIELD_ASSIGNMENT_GROUP = 'Назначение'
    FIELD_WATCHER_GROUPS = 'Наблюдатели'
    FIELD_DURATION_DAYS = 'Срок выполнения'
    FIELD_WORKING_DAYS_ONLY = 'Только рабочие дни'
    FIELD_INTERVAL_UNIT = 'Единица интервала'
    FIELD_INTERVAL_VALUE = 'Интервал'
    FIELD_DAY_NUMBER = 'Число'
    FIELD_REPEAT_DAYS = 'Дни повторения'
    FIELD_MONTH = 'Месяц'
    FIELD_SUBTASK_ORDER = 'Порядковый номер'
    FIELD_PARENT_ISSUE = 'Родительская задача'
    
    # ========================================================================
    # Поля для основных задач
    # ========================================================================
    MAIN_TASK_FIELDS = [
      FIELD_TARGET_PROJECT,
      FIELD_TARGET_TRACKER,
      FIELD_ASSIGNMENT_GROUP,
      FIELD_WATCHER_GROUPS,
      FIELD_INTERVAL_UNIT,
      FIELD_INTERVAL_VALUE,
      FIELD_DAY_NUMBER,
      FIELD_REPEAT_DAYS,
      FIELD_MONTH,
      FIELD_CREATE_AHEAD_DAYS,
      FIELD_DURATION_DAYS,
      FIELD_NEXT_EXECUTION_DATE,
      FIELD_WORKING_DAYS_ONLY
    ].freeze
    
    # ========================================================================
    # Поля для подзадач
    # ========================================================================
    SUBTASK_FIELDS = [
      FIELD_PARENT_ISSUE,
      FIELD_TARGET_TRACKER,
      FIELD_ASSIGNMENT_GROUP,
      FIELD_SUBTASK_ORDER,
      FIELD_DURATION_DAYS,
      FIELD_WORKING_DAYS_ONLY
    ].freeze

    # ========================================================================
    # Все необходимые поля (для обратной совместимости)
    # ========================================================================
    REQUIRED_CUSTOM_FIELDS = (MAIN_TASK_FIELDS + SUBTASK_FIELDS).uniq.freeze

    # ========================================================================
    # Настройки плагина по умолчанию
    # ========================================================================
    DEFAULT_SETTINGS = {
      'source_project_id' => '',
      'author_id' => '',
      'tracker_id' => '',
      'subtask_tracker_id' => '',
      'error_notification_email' => ''
    }.freeze
  end
end