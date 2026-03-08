# ============================================================================
# Файл: lib/tasks/task_automation.rake
# Назначение: Rake-задача для запуска автоматизации задач через cron
# ============================================================================

namespace :redmine do
  namespace :task_automation do
    desc 'Запуск автоматической обработки задач-шаблонов'
    task process: :environment do
      puts '=' * 60
      puts I18n.t('task_automation.rake.process_start')
      puts '=' * 60
      puts ""
      start_time = Time.now
      puts I18n.t('task_automation.rake.start_time', time: start_time.strftime('%Y-%m-%d %H:%M:%S'))
      puts ""

      begin
        # Проверка наличия плагина (теперь Redmine уже загружен)
        unless Redmine::Plugin.registered_plugins.has_key?(:redmine_task_automation)
          puts "[ERROR] Плагин redmine_task_automation не найден!"
          exit 1
        end

        result = TaskAutomation::Service.process

        puts ""
        puts '-' * 60
        puts I18n.t('task_automation.rake.results')
        puts '-' * 60
        status_text = result[:success] ?
          I18n.t('task_automation.status.success') :
          I18n.t('task_automation.status.error')
        puts "#{I18n.t('task_automation.rake.status')}: #{status_text}"
        puts "#{I18n.t('task_automation.rake.issues_created')}: #{result[:created_count]}"
        puts "#{I18n.t('task_automation.rake.subtasks_created')}: #{result[:subtasks_count]}"

        if result[:errors].any?
          puts ""
          puts "#{I18n.t('task_automation.rake.errors_count')}: #{result[:errors].count}"
          puts ""
          puts I18n.t('task_automation.rake.error_details')
          result[:errors].each_with_index do |error, index|
            puts "  #{index + 1}. #{error}"
          end
        end

        end_time = Time.now
        duration = end_time - start_time

        puts ""
        puts '-' * 60
        puts I18n.t('task_automation.rake.end_time', time: end_time.strftime('%Y-%m-%d %H:%M:%S'))
        puts I18n.t('task_automation.rake.duration', seconds: duration.round(2))
        puts '=' * 60

        exit(result[:success] ? 0 : 1)

      rescue => e
        puts ""
        puts '=' * 60
        puts I18n.t('task_automation.rake.critical_error')
        puts '=' * 60
        puts "#{I18n.t('task_automation.rake.error_message')}: #{e.message}"
        puts ""
        puts I18n.t('task_automation.rake.backtrace')
        puts e.backtrace.join("\n")
        puts '=' * 60

        Rails.logger.error "[TaskAutomation Rake] Критическая ошибка: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")

        exit(1)
      end
    end

    desc 'Тестирование настроек плагина автоматизации'
    task test: :environment do
      puts '=' * 60
      puts I18n.t('task_automation.rake.test_start')
      puts '=' * 60
      puts ""

      begin
        settings = Setting.plugin_redmine_task_automation

        puts I18n.t('task_automation.rake.testing_settings')
        puts '-' * 60

        # Проверка проекта
        project_id = settings['source_project_id'].to_i
        if project_id > 0
          project = Project.find_by(id: project_id)
          if project
            puts "✓ #{I18n.t('task_automation.test.project_found', name: project.name)}"
          else
            puts "✗ #{I18n.t('task_automation.test.project_not_found')}"
          end
        else
          puts "⚠ #{I18n.t('task_automation.test.project_not_selected')}"
        end

        # Проверка автора
        author_id = settings['author_id'].to_i
        if author_id > 0
          author = User.find_by(id: author_id)
          if author
            puts "✓ #{I18n.t('task_automation.test.author_found', name: author.login)}"
          else
            puts "✗ #{I18n.t('task_automation.test.author_not_found')}"
          end
        else
          puts "⚠ #{I18n.t('task_automation.test.author_not_selected')}"
        end

        # Проверка трекера
        tracker_id = settings['tracker_id'].to_i
        if tracker_id > 0
          tracker = Tracker.find_by(id: tracker_id)
          if tracker
            puts "✓ #{I18n.t('task_automation.test.tracker_found', name: tracker.name)}"
          else
            puts "✗ #{I18n.t('task_automation.test.tracker_not_found')}"
          end
        else
          puts "⚠ #{I18n.t('task_automation.test.tracker_not_selected')}"
        end

        # Проверка кастомных полей
        puts ""
        puts I18n.t('task_automation.rake.testing_custom_fields')
        puts '-' * 60

        missing_fields = TaskAutomation::Service.check_missing_custom_fields

        if missing_fields.empty?
          puts "✓ #{I18n.t('task_automation.test.custom_fields_found')}"

          fields_with_ids = TaskAutomation::Service.get_all_custom_fields_with_ids
          fields_with_ids.each do |field_name, field_id|
            if field_id.present?
              puts "  ✓ #{field_name} (ID: #{field_id})"
            end
          end
        else
          missing_fields.each do |field_name|
            puts "✗ #{field_name} - #{I18n.t('task_automation.test.field_not_found_short')}"
          end
        end

        puts ""
        puts '=' * 60
        puts I18n.t('task_automation.rake.test_complete')
        puts '=' * 60

      rescue => e
        puts ""
        puts '=' * 60
        puts I18n.t('task_automation.rake.test_error')
        puts '=' * 60
        puts "#{I18n.t('task_automation.rake.error_message')}: #{e.message}"
        puts '=' * 60

        exit(1)
      end
    end

    desc 'Очистка журнала логов автоматизации'
    task clear_log: :environment do
      log_file = Rails.root.join('log', 'task_automation.log')

      if File.exist?(log_file)
        File.delete(log_file)
        puts I18n.t('task_automation.rake.log_cleared')
      else
        puts I18n.t('task_automation.rake.log_not_found')
      end
    end

    desc 'Показать статус и настройки плагина'
    task status: :environment do
      puts '=' * 60
      puts I18n.t('task_automation.rake.plugin_status')
      puts '=' * 60
      puts ""

      settings = Setting.plugin_redmine_task_automation

      puts "#{I18n.t('task_automation.settings.source_project_id')}: #{settings['source_project_id'] || 'Не указано'}"
      puts "#{I18n.t('task_automation.settings.author_id')}: #{settings['author_id'] || 'Не указано'}"
      puts "#{I18n.t('task_automation.settings.tracker_id')}: #{settings['tracker_id'] || 'Не указано'}"
      puts "#{I18n.t('task_automation.settings.error_notification_email')}: #{settings['error_notification_email'] || 'Не указано'}"
      puts ""
      puts '=' * 60
    end
  end
end