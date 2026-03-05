# ============================================================================
# Файл: config/routes.rb
# Назначение: Определение маршрутов для контроллера настроек плагина
# ============================================================================
RedmineApp::Application.routes.draw do
  # Маршрут для ручного запуска обработки
  post '/settings/plugin/redmine_task_automation/run',
    to: 'task_automation_settings#test_run',
    as: 'task_automation_run'
  
  # Маршрут для тестирования настроек
  post '/settings/plugin/redmine_task_automation/test',
    to: 'task_automation_settings#test',
    as: 'task_automation_test'
  
  # НОВЫЙ маршрут для очистки результатов тестирования
  get '/settings/plugin/redmine_task_automation/clear_test',
    to: 'task_automation_settings#clear_test_results',
    as: 'task_automation_clear_test'
end