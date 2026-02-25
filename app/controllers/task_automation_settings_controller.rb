# ============================================================================
# Файл: app/controllers/task_automation_settings_controller.rb
# ============================================================================

class TaskAutomationSettingsController < ApplicationController
  before_action :require_login
  before_action :require_admin
  before_action :load_settings, only: [:index, :update, :test_run, :test]
  
  def index
    @projects = Project.active.sorted
    @users = User.active.sorted
    @trackers = Tracker.sorted
    @groups = Group.sorted
    @custom_fields_info = TaskAutomation::Service.get_all_custom_fields_with_ids
    
    render partial: 'settings/task_automation_settings', locals: { settings: @settings }
  end
  
  def update
    begin
      params_settings = params[:settings]
      validation_errors = validate_settings_params(params_settings)
      
      if validation_errors.any?
        flash[:error] = validation_errors.join('<br/>').html_safe
        @projects = Project.active.sorted
        @users = User.active.sorted
        @trackers = Tracker.sorted
        @groups = Group.sorted
        @custom_fields_info = TaskAutomation::Service.get_all_custom_fields_with_ids
        render partial: 'settings/task_automation_settings', locals: { settings: params_settings }
        return
      end
      
      Setting.plugin_redmine_task_automation = {
        'source_project_id' => params_settings[:source_project_id].to_i,
        'author_id' => params_settings[:author_id].to_i,
        'tracker_id' => params_settings[:tracker_id].to_i,
        'error_notification_email' => params_settings[:error_notification_email]
      }
      
      flash[:notice] = I18n.t('task_automation.flash.settings_saved')
      
    rescue => e
      Rails.logger.error "[TaskAutomation] Ошибка сохранения настроек: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      flash[:error] = I18n.t('task_automation.flash.settings_save_error', error: e.message)
    end
    
    redirect_to controller: 'task_automation_settings', action: 'index'
  end
  
  def test_run
    Rails.logger.info "[TaskAutomation] Запущен ручной запуск обработки задач"
    
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
          Rails.logger.error "[TaskAutomation] #{error}"
        end
      end
      
    rescue => e
      Rails.logger.error "[TaskAutomation] Критическая ошибка при ручном запуске: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      flash[:error] = I18n.t('task_automation.flash.run_error', error: e.message)
    end
    
    redirect_to controller: 'task_automation_settings', action: 'index'
  end
  
  def test
    test_results = []
    
    begin
      project_id = @settings[:source_project_id].to_i
      if project_id > 0
        project = Project.find_by(id: project_id)
        if project
          test_results << { status: 'success', message: I18n.t('task_automation.test.project_found', name: project.name) }
        else
          test_results << { status: 'error', message: I18n.t('task_automation.test.project_not_found') }
        end
      else
        test_results << { status: 'warning', message: I18n.t('task_automation.test.project_not_selected') }
      end
      
      author_id = @settings[:author_id].to_i
      if author_id > 0
        author = User.find_by(id: author_id)
        if author
          test_results << { status: 'success', message: I18n.t('task_automation.test.author_found', name: author.login) }
        else
          test_results << { status: 'error', message: I18n.t('task_automation.test.author_not_found') }
        end
      else
        test_results << { status: 'warning', message: I18n.t('task_automation.test.author_not_selected') }
      end
      
      tracker_id = @settings[:tracker_id].to_i
      if tracker_id > 0
        tracker = Tracker.find_by(id: tracker_id)
        if tracker
          test_results << { status: 'success', message: I18n.t('task_automation.test.tracker_found', name: tracker.name) }
        else
          test_results << { status: 'error', message: I18n.t('task_automation.test.tracker_not_found') }
        end
      else
        test_results << { status: 'warning', message: I18n.t('task_automation.test.tracker_not_selected') }
      end
      
      email = @settings[:error_notification_email]
      if email.present?
        if email.match?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
          test_results << { status: 'success', message: I18n.t('task_automation.test.email_valid') }
        else
          test_results << { status: 'error', message: I18n.t('task_automation.test.email_invalid') }
        end
      else
        test_results << { status: 'warning', message: I18n.t('task_automation.test.email_not_set') }
      end
      
      missing_fields = TaskAutomation::Service.check_missing_custom_fields
      
      if missing_fields.empty?
        test_results << { status: 'success', message: I18n.t('task_automation.test.custom_fields_found') }
      else
        test_results << { status: 'error', message: I18n.t('task_automation.test.custom_fields_missing', fields: missing_fields.join(', ')) }
      end
      
    rescue => e
      Rails.logger.error "[TaskAutomation] Ошибка тестирования настроек: #{e.message}"
      test_results << { status: 'error', message: I18n.t('task_automation.test.general_error', error: e.message) }
    end
    
    session[:task_automation_test_results] = test_results
    redirect_to controller: 'task_automation_settings', action: 'index'
  end
  
  private
  
  def load_settings
    raw_settings = Setting.plugin_redmine_task_automation
    @settings = {
      source_project_id: raw_settings['source_project_id'].to_i,
      author_id: raw_settings['author_id'].to_i,
      tracker_id: raw_settings['tracker_id'].to_i,
      error_notification_email: raw_settings['error_notification_email'] || ''
    }
  end
  
  def validate_settings_params(params_settings)
    errors = []
    
    if params_settings[:source_project_id].blank? || params_settings[:source_project_id].to_i == 0
      errors << I18n.t('task_automation.validation.source_project_required')
    else
      unless Project.exists?(params_settings[:source_project_id].to_i)
        errors << I18n.t('task_automation.validation.source_project_not_found')
      end
    end
    
    if params_settings[:author_id].blank? || params_settings[:author_id].to_i == 0
      errors << I18n.t('task_automation.validation.author_required')
    else
      unless User.exists?(params_settings[:author_id].to_i)
        errors << I18n.t('task_automation.validation.author_not_found')
      end
    end
    
    if params_settings[:tracker_id].blank? || params_settings[:tracker_id].to_i == 0
      errors << I18n.t('task_automation.validation.tracker_required')
    else
      unless Tracker.exists?(params_settings[:tracker_id].to_i)
        errors << I18n.t('task_automation.validation.tracker_not_found')
      end
    end
    
    if params_settings[:error_notification_email].present?
      unless params_settings[:error_notification_email].match?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
        errors << I18n.t('task_automation.validation.email_invalid')
      end
    end
    
    errors
  end
end