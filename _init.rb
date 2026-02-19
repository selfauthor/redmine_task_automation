# ============================================================================
# Файл: init.rb
# Назначение: Инициализация плагина Redmine Task Automation
# ============================================================================

Redmine::Plugin.register :redmine_task_automation do
  
  # ==========================================================================
  # ОСНОВНАЯ ИНФОРМАЦИЯ О ПЛАГИНЕ
  # ==========================================================================
  
  name 'Redmine Task Automation'
  description 'Автоматическое создание задач на основе шаблонов с расписанием выполнения'
  author 'Андрей Якушев'
  url 'https://github.com/selfauthor/redmine-task-automation'
  version '1.0.0'
  
  # Минимальная версия Redmine, необходимая для работы плагина
  requires_redmine version_or_higher: '6.0.0'
  
  # Настройки плагина, хранящиеся в стандартной таблице settings
  settings(
    default: TaskAutomation::Configuration::DEFAULT_SETTINGS,
    partial: 'settings/task_automation_settings'
  )
  
  # Добавление пункта меню в административном разделе Redmine
  menu :admin_menu, :task_automation,
    { controller: 'task_automation_settings', action: 'index' },
    caption: :label_task_automation,
    after: :plugins,
    html: { class: 'task-automation-menu' }
end

# ============================================================================
# Подключение модуля конфигурации (должен быть загружен первым)
# ============================================================================
require_dependency 'task_automation/configuration'

# ============================================================================
# Подключение основных файлов плагина
# ============================================================================
require_dependency 'task_automation'
require_dependency 'task_automation/task_processor'