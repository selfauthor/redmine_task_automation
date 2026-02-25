# ============================================================================
# Файл: init.rb
# Назначение: Инициализация плагина Redmine Task Automation
# ============================================================================

# ============================================================================
# Регистрация плагина в системе Redmine
# Файлы из app/models/task_automation/ загрузятся автоматически через Zeitwerk
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
  # Используем литерал вместо ссылки на константу (константа загрузится позже)
  settings(
    default: {
      'source_project_id' => '',
      'author_id' => '',
      'tracker_id' => '',
      'error_notification_email' => ''
    },
    partial: 'settings/task_automation_settings'
  )
  
  menu :admin_menu, :task_automation,
    { controller: 'task_automation_settings', action: 'index' },
    caption: :label_task_automation,
    after: :plugins,
    html: { class: 'task-automation-menu' }
end
