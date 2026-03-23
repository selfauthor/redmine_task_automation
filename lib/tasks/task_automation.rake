# ============================================================================
# Файл: lib/tasks/task_automation.rake
# Назначение: Rake-задача для запуска автоматизации задач через cron
# ============================================================================

namespace :redmine do
  namespace :task_automation do
    desc 'Запуск автоматической обработки задач-шаблонов'
    task process: :environment do
      # ======================================================================
      # Установка локали из настроек Redmine или по умолчанию :ru (ОБЯЗАТЕЛЬНО для cron!)
      # ======================================================================
      begin
        I18n.locale = Setting.default_language.to_sym
      rescue
        I18n.locale = :ru
      end
      Rails.logger.info "[TaskAutomation] Установлена локаль: #{I18n.locale}"

      # ======================================================================
      # Логирование в тот же файл что и плагин (log/task_automation.log)
      # ======================================================================
      log_file_path = Rails.root.join('log', 'task_automation.log')
      log_dir = File.dirname(log_file_path)
      FileUtils.mkdir_p(log_dir) unless File.directory?(log_dir)
      
      # Функция для записи в лог с тем же форматом что и в плагине
      def log_to_file(message, level = 'INFO', issue_id = nil)
        log_file_path = Rails.root.join('log', 'task_automation.log')
        timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
        
        log_entry = "[#{timestamp}] [#{level}] "
        log_entry += "[Issue ##{issue_id}] " if issue_id
        log_entry += "#{message} "
        
        File.open(log_file_path, 'a') { |f| f.puts(log_entry) }
      end
      
      # ======================================================================
      # Блокировка от параллельного запуска (lock file)
      # ======================================================================
      lock_file = Rails.root.join('tmp', 'pids', 'task_automation.lock')
      FileUtils.mkdir_p(File.dirname(lock_file)) unless File.directory?(File.dirname(lock_file))
      
      if File.exist?(lock_file)
        pid = File.read(lock_file).to_i
        begin
          if Process.kill(0, pid)
            log_to_file('Другой процесс уже выполняется (запуск отменён)', 'ERROR')
            puts "[ERROR] Другой процесс уже выполняется (PID: #{pid})"
            exit(1)
          end
        rescue Errno::ESRCH
          # Процесс не найден, удаляем stale lock file
          File.delete(lock_file)
          log_to_file('Stale lock file удалён', 'WARNING')
        end
      end
      
      File.write(lock_file, Process.pid)
      log_to_file('Lock file создан', 'INFO')
      
      begin
        # ====================================================================
        # Основной блок выполнения
        # ====================================================================
        log_to_file('=== Запуск обработки задач-шаблонов (CRON) ===', 'INFO')
        
        puts '=' * 60
        puts I18n.t('task_automation.rake.process_start')
        puts '=' * 60
        puts ""
        
        start_time = Time.now
        log_to_file("Время начала: #{start_time.strftime('%Y-%m-%d %H:%M:%S')}", 'INFO')
        puts I18n.t('task_automation.rake.start_time', time: start_time.strftime('%Y-%m-%d %H:%M:%S'))
        puts ""
        
        begin
          # Проверка наличия плагина
          unless Redmine::Plugin.registered_plugins.has_key?(:redmine_task_automation)
            log_to_file('Плагин redmine_task_automation не найден!', 'ERROR')
            puts "[ERROR] Плагин redmine_task_automation не найден!"
            exit 1
          end
          
          log_to_file('Запуск TaskAutomation::Service.process...', 'INFO')
          result = TaskAutomation::Service.process
          
          # Логирование результатов
          log_to_file("Статус: #{result[:success] ? 'Успешно' : 'Ошибка'}", result[:success] ? 'INFO' : 'ERROR')
          log_to_file("Создано задач: #{result[:created_count]}", 'INFO')
          log_to_file("Создано подзадач: #{result[:subtasks_count]}", 'INFO')
          
          if result[:errors].any?
            log_to_file("Количество ошибок: #{result[:errors].count}", 'ERROR')
            result[:errors].each do |error|
              log_to_file(error, 'ERROR')
            end
          end
          
          if result[:warnings].any?
            log_to_file("Количество предупреждений: #{result[:warnings].count}", 'WARNING')
            result[:warnings].each do |warning|
              log_to_file(warning, 'WARNING')
            end
          end
          
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
          
        rescue => e
          log_to_file("Критическая ошибка: #{e.class}: #{e.message}", 'ERROR')
          log_to_file("Backtrace: #{e.backtrace.first(10).join(' ')}", 'ERROR')
          
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
        
        end_time = Time.now
        duration = end_time - start_time
        
        log_to_file("Время окончания: #{end_time.strftime('%Y-%m-%d %H:%M:%S')}", 'INFO')
        log_to_file("Длительность: #{duration.round(2)} сек.", 'INFO')
        log_to_file('=== Обработка завершена ===', 'INFO')
        
        puts ""
        puts '-' * 60
        puts I18n.t('task_automation.rake.end_time', time: end_time.strftime('%Y-%m-%d %H:%M:%S'))
        puts I18n.t('task_automation.rake.duration', seconds: duration.round(2))
        puts '=' * 60
        
        exit(result[:success] ? 0 : 1)
        
      ensure
        # ====================================================================
        # Очистка lock file
        # ====================================================================
        if File.exist?(lock_file)
          File.delete(lock_file)
          log_to_file('Lock file удалён', 'INFO')
        end
      end
    end

    # ========================================================================
    # Следующие задания были созданы на случай необходимости запуска их либо
    # через cron, либо из командной строки.
    # В текущей работе они не используются, но оставлены на случай необходимости
    # ========================================================================

    # ========================================================================
    # Тестирование настроек плагина
    # ========================================================================
    desc 'Тестирование настроек плагина автоматизации'
    task test: :environment do
      log_file_path = Rails.root.join('log', 'task_automation.log')
      
      def log_to_file(message, level = 'INFO', issue_id = nil)
        log_file_path = Rails.root.join('log', 'task_automation.log')
        timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
        log_entry = "[#{timestamp}] [#{level}] "
        log_entry += "[Issue ##{issue_id}] " if issue_id
        log_entry += "#{message} "
        File.open(log_file_path, 'a') { |f| f.puts(log_entry) }
      end
      
      log_to_file('=== Тестирование настроек (CRON) ===', 'INFO')
      
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
            log_to_file("Проект найден: #{project.name}", 'INFO')
            puts "✓ #{I18n.t('task_automation.test.project_found', name: project.name)}"
          else
            log_to_file('Проект не найден', 'ERROR')
            puts "✗ #{I18n.t('task_automation.test.project_not_found')}"
          end
        else
          log_to_file('Проект не выбран', 'WARNING')
          puts "⚠ #{I18n.t('task_automation.test.project_not_selected')}"
        end
        
        # Проверка автора
        author_id = settings['author_id'].to_i
        if author_id > 0
          author = User.find_by(id: author_id)
          if author
            log_to_file("Автор найден: #{author.login}", 'INFO')
            puts "✓ #{I18n.t('task_automation.test.author_found', name: author.login)}"
          else
            log_to_file('Автор не найден', 'ERROR')
            puts "✗ #{I18n.t('task_automation.test.author_not_found')}"
          end
        else
          log_to_file('Автор не выбран', 'WARNING')
          puts "⚠ #{I18n.t('task_automation.test.author_not_selected')}"
        end
        
        # Проверка трекера
        tracker_id = settings['tracker_id'].to_i
        if tracker_id > 0
          tracker = Tracker.find_by(id: tracker_id)
          if tracker
            log_to_file("Трекер найден: #{tracker.name}", 'INFO')
            puts "✓ #{I18n.t('task_automation.test.tracker_found', name: tracker.name)}"
          else
            log_to_file('Трекер не найден', 'ERROR')
            puts "✗ #{I18n.t('task_automation.test.tracker_not_found')}"
          end
        else
          log_to_file('Трекер не выбран', 'WARNING')
          puts "⚠ #{I18n.t('task_automation.test.tracker_not_selected')}"
        end
        
        # Проверка кастомных полей
        puts ""
        puts I18n.t('task_automation.rake.testing_custom_fields')
        puts '-' * 60
        
        missing_fields = TaskAutomation::Service.check_missing_custom_fields
        if missing_fields.empty?
          log_to_file('Все кастомные поля найдены', 'INFO')
          puts "✓ #{I18n.t('task_automation.test.custom_fields_found')}"
          fields_with_ids = TaskAutomation::Service.get_all_custom_fields_with_ids
          fields_with_ids.each do |field_name, field_id|
            if field_id.present?
              puts "  ✓ #{field_name} (ID: #{field_id})"
            end
          end
        else
          missing_fields.each do |field_name|
            log_to_file("Поле не найдено: #{field_name}", 'ERROR')
            puts "✗ #{field_name} - #{I18n.t('task_automation.test.field_not_found_short')}"
          end
        end
        
        log_to_file('=== Тестирование завершено ===', 'INFO')
        
        puts ""
        puts '=' * 60
        puts I18n.t('task_automation.rake.test_complete')
        puts '=' * 60
        
      rescue => e
        log_to_file("Ошибка тестирования: #{e.message}", 'ERROR')
        
        puts ""
        puts '=' * 60
        puts I18n.t('task_automation.rake.test_error')
        puts '=' * 60
        puts "#{I18n.t('task_automation.rake.error_message')}: #{e.message}"
        puts '=' * 60
        
        exit(1)
      end
    end
    
    # ========================================================================
    # Очистка журнала логов
    # ========================================================================
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
    
    # ========================================================================
    # Показать статус и настройки плагина
    # ========================================================================
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
      puts "#{I18n.t('task_automation.settings.subtask_tracker_id')}: #{settings['subtask_tracker_id'] || 'Не указано'}"
      puts ""
      puts '=' * 60
    end
  end
end