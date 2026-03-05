# ============================================================================
# Файл: app/controllers/task_automation_settings_controller.rb
# Назначение: Контроллер для тестирования и ручного запуска автоматизации
# ============================================================================
class TaskAutomationSettingsController < ApplicationController
  before_action :require_login
  before_action :require_admin
  before_action :load_settings, only: [:test_run, :test]

  def test_run
    Rails.logger.info "[TaskAutomation] Запущен ручной запуск обработки задач "
    begin
      result = TaskAutomation::Service.process

      if result[:success]
        message = I18n.t('task_automation.flash.run_success',
                         issues: result[:created_count],
                         subtasks: result[:subtasks_count])
        flash[:notice] = message
      else
        message = I18n.t('task_automation.flash.run_with_errors',
                         issues: result[:created_count],
                         errors: result[:errors].count)
        flash[:warning] = message

        result[:errors].each do |error|
          Rails.logger.error "[TaskAutomation] #{error} "
        end
      end

    rescue => e
      Rails.logger.error "[TaskAutomation] Критическая ошибка при ручном запуске: #{e.message} "
      Rails.logger.error e.backtrace.join("\n")
      flash[:error] = I18n.t('task_automation.flash.run_error', error: e.message)
    end

    redirect_to controller: 'settings', action: 'plugin', id: 'redmine_task_automation'
  end

  def test
    test_results = []
    begin
      # ========================================================================
      # 1. Проверка проекта-источника
      # ========================================================================
      project_id = @settings[:source_project_id].to_i
      if project_id > 0
        project = Project.find_by(id: project_id)
        if project
          test_results << { status: 'success', message: I18n.t('task_automation.test.project_found', name: project.name) }

          # ====================================================================
          # 2. Проверка доступности трекера в проекте
          # ====================================================================
          tracker_id = @settings[:tracker_id].to_i
          if tracker_id > 0
            if TaskAutomation::Service.tracker_available_in_project?(project_id, tracker_id)
              test_results << { status: 'success', message: I18n.t('task_automation.test.tracker_in_project') }
            else
              test_results << { status: 'error', message: I18n.t('task_automation.test.tracker_not_in_project') }
            end
          end
        else
          test_results << { status: 'error', message: I18n.t('task_automation.test.project_not_found') }
        end
      else
        test_results << { status: 'warning', message: I18n.t('task_automation.test.project_not_selected') }
      end

      # ========================================================================
      # 3. Проверка пользователя-автора
      # ========================================================================
      author_id = @settings[:author_id].to_i
      if author_id > 0
        author = User.find_by(id: author_id)
        if author
          test_results << { status: 'success', message: I18n.t('task_automation.test.author_found', name: author.login) }

          # ===================================================================
          # 4. Проверка прав автора на чтение и редактирование задач
          # ===================================================================
          permission_issues = TaskAutomation::Service.check_author_permissions(author_id, project_id)

          if permission_issues.empty?
            test_results << { status: 'success', message: I18n.t('task_automation.test.author_has_permissions') }
          else
            permission_issues.each do |issue|
              test_results << { status: issue[:type], message: issue[:message] }
            end
          end
        else
          test_results << { status: 'error', message: I18n.t('task_automation.test.author_not_found') }
        end
      else
        test_results << { status: 'warning', message: I18n.t('task_automation.test.author_not_selected') }
      end

      # ========================================================================
      # 5. Проверка трекера
      # ========================================================================
      tracker_id = @settings[:tracker_id].to_i
      if tracker_id > 0
        tracker = Tracker.find_by(id: tracker_id)
        if tracker
          test_results << { status: 'success', message: I18n.t('task_automation.test.tracker_found', name: tracker.name) }

          # ==================================================================
          # 6. Проверка доступности кастомных полей для трекера основных задач
          # ==================================================================
          main_tracker_id = @settings[:tracker_id].to_i
          if main_tracker_id > 0
            main_tracker = Tracker.find_by(id: main_tracker_id)
            if main_tracker
              unavailable_main_fields = TaskAutomation::Service.check_main_task_fields(main_tracker_id)

              if unavailable_main_fields.empty?
                test_results << { status: 'success', message: I18n.t('task_automation.test.main_fields_available') }
              else
                test_results << {
                  status: 'error',
                  message: I18n.t('task_automation.test.main_fields_not_available',
                                  tracker: main_tracker.name,
                                  fields: unavailable_main_fields.join(', '))
                }
              end
            end
          end

          # ================================================================
          # 7. Проверка трекера подзадач
          # ================================================================
          subtask_tracker_id = @settings[:subtask_tracker_id].to_i
          if subtask_tracker_id > 0
            subtask_tracker = Tracker.find_by(id: subtask_tracker_id)
            if subtask_tracker
              test_results << {
                status: 'success',
                message: I18n.t('task_automation.test.subtask_tracker_found', name: subtask_tracker.name)
              }

              # ===========================================================
              # 8. Проверка доступности полей для трекера подзадач
              # ===========================================================
              unavailable_subtask_fields = TaskAutomation::Service.check_subtask_fields(subtask_tracker_id)

              if unavailable_subtask_fields.empty?
                test_results << { status: 'success', message: I18n.t('task_automation.test.subtask_fields_available') }
              else
                test_results << {
                  status: 'error',
                  message: I18n.t('task_automation.test.subtask_fields_not_available',
                                  tracker: subtask_tracker.name,
                                  fields: unavailable_subtask_fields.join(', '))
                }
              end

              # ===========================================================
              # 9. Проверка типов полей для подзадач
              # ===========================================================
              invalid_subtask_fields = TaskAutomation::Service.check_subtask_field_types

              if invalid_subtask_fields.empty?
                test_results << { status: 'success', message: I18n.t('task_automation.test.subtask_field_types_correct') }
              else
                invalid_subtask_fields.each do |field_info|
                  test_results << {
                    status: 'error',
                    message: I18n.t('task_automation.test.subtask_field_type_invalid',
                                    field: field_info[:field],
                                    expected: field_info[:expected],
                                    actual: field_info[:actual])
                  }
                end
              end
            else
              test_results << { status: 'error', message: I18n.t('task_automation.test.subtask_tracker_not_found') }
            end
          else
            test_results << { status: 'warning', message: I18n.t('task_automation.test.subtask_tracker_not_selected') }
          end
        end
      end

      # ========================================================================
      # Запись результатов в журнал
      # ========================================================================
      TaskAutomation::Service.log_test_results(test_results)

    rescue => e
      Rails.logger.error "[TaskAutomation] Ошибка тестирования настроек: #{e.message}  "
      test_results << { status: 'error', message: I18n.t('task_automation.test.general_error', error: e.message) }
      TaskAutomation::Service.log_message('error', "[ТЕСТ] Критическая ошибка: #{e.message}  ")
    end

    session[:task_automation_test_results] = test_results
    redirect_to controller: 'settings', action: 'plugin', id: 'redmine_task_automation'
  end

  def clear_test_results
    Rails.logger.info "[TaskAutomation] Очистка результатов тестирования"
    session[:task_automation_test_results] = nil
    flash[:notice] = I18n.t('task_automation.flash.test_results_cleared')

    redirect_to controller: 'settings', action: 'plugin', id: 'redmine_task_automation'
  end

  private

  def load_settings
    raw_settings = Setting.plugin_redmine_task_automation
    @settings = {
      source_project_id: raw_settings['source_project_id'].to_i,
      author_id: raw_settings['author_id'].to_i,
      tracker_id: raw_settings['tracker_id'].to_i,
      subtask_tracker_id: raw_settings['subtask_tracker_id'].to_i,
      error_notification_email: raw_settings['error_notification_email'] || ''
    }
  end

  # ==========================================================================
  # НОВЫЙ МЕТОД: Валидация параметров настроек
  # ==========================================================================
  def validate_settings_params(params_settings)
    errors = []

    # Проверка проекта-источника
    if params_settings[:source_project_id].blank? || params_settings[:source_project_id].to_i == 0
      errors << I18n.t('task_automation.validation.source_project_required')
    else
      unless Project.exists?(params_settings[:source_project_id].to_i)
        errors << I18n.t('task_automation.validation.source_project_not_found')
      end
    end

    # Проверка пользователя-автора
    if params_settings[:author_id].blank? || params_settings[:author_id].to_i == 0
      errors << I18n.t('task_automation.validation.author_required')
    else
      unless User.exists?(params_settings[:author_id].to_i)
        errors << I18n.t('task_automation.validation.author_not_found')
      end
    end

    # Проверка трекера основных задач
    if params_settings[:tracker_id].blank? || params_settings[:tracker_id].to_i == 0
      errors << I18n.t('task_automation.validation.tracker_required')
    else
      unless Tracker.exists?(params_settings[:tracker_id].to_i)
        errors << I18n.t('task_automation.validation.tracker_not_found')
      end
    end

    # Проверка трекера подзадач (НОВОЕ)
    if params_settings[:subtask_tracker_id].present? && params_settings[:subtask_tracker_id].to_i > 0
      unless Tracker.exists?(params_settings[:subtask_tracker_id].to_i)
        errors << I18n.t('task_automation.validation.subtask_tracker_not_found')
      end
    end

    # Проверка email
    if params_settings[:error_notification_email].present?
      unless params_settings[:error_notification_email].match?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
        errors << I18n.t('task_automation.validation.email_invalid')
      end
    end

    errors
  end
end