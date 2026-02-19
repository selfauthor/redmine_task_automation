# ============================================================================
# Файл: config/routes.rb
# Назначение: Определение маршрутов для контроллера настроек плагина
# ============================================================================

# Добавление маршрутов для контроллера настроек плагина
RedmineApp::Application.routes.draw do
  # Маршруты для страницы настроек плагина
  match '/settings/plugin/redmine_task_automation', 
    to: 'task_automation_settings#index', 
    via: [:get, :post],
    as: 'task_automation_settings'
  
  # Маршрут для ручного запуска обработки
  match '/settings/plugin/redmine_task_automation/run', 
    to: 'task_automation_settings#test_run', 
    via: [:post],
    as: 'task_automation_run'
  
  # Маршрут для тестирования настроек
  match '/settings/plugin/redmine_task_automation/test', 
    to: 'task_automation_settings#test', 
    via: [:post],
    as: 'task_automation_test'
end