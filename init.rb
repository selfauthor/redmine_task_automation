# ============================================================================
# Файл: init.rb
# ============================================================================

Redmine::Plugin.register :redmine_task_automation do
  name 'Автоматизация задач Redmine'
  description 'Автоматическое создание задач на основе шаблонов с расписанием выполнения'
  author 'Андрей Якушев'
  author_url 'https://a2ya.ru'
  url 'https://github.com/selfauthor/redmine-task-automation'
  version '1.0.0'
  requires_redmine version_or_higher: '5.0.0'
  
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
    '/settings/plugin/redmine_task_automation',
    caption: :label_task_automation,
    after: :plugins,
    html: { class: 'icon icon-task_automation task-automation-menu' }
end

# ============================================================================
# Хук для добавления CSS на все страницы (включая /admin)
# ============================================================================
Rails.application.config.to_prepare do
  Redmine::Hooks.register_listener 'view_layouts_base_html_head', 
    module: RedmineTaskAutomation::Hooks::LayoutHook
  
  SettingsController.class_eval do
    before_action :init_task_automation_variables, 
      if: -> { params[:id] == 'redmine_task_automation' && action_name == 'plugin' }
    
    private
    
    def init_task_automation_variables
      @projects = Project.active.sorted
      @users = User.active.sorted
      @trackers = Tracker.sorted
      @groups = Group.sorted
    end
  end
end

# ============================================================================
# Модуль хуков для добавления глобальных стилей
# ============================================================================
module RedmineTaskAutomation
  module Hooks
    class LayoutHook < Redmine::Hook::ViewListener
		def view_layouts_base_html_head(context={})
		  <<-HTML.html_safe  # ← Правильный синтаксис
			<style>
			  /* Убираем padding-left для нашего пункта меню */
			  #admin-menu a.icon-task_automation,
			  #admin-menu .task-automation-menu {
				padding-left: 0 !important;
			  }

			  /* Иконка автоматизации задач - цвет #169 */
			  #admin-menu a.icon-task_automation:before,
			  .icon-task_automation:before {
				content: '';
				display: inline-block;
				width: 16px;
				height: 16px;
				margin-right: 4px;
				vertical-align: text-bottom;
				background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23169' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Ccircle cx='12' cy='12' r='10'/%3E%3Cpolyline points='12 6 12 12 16 14'/%3E%3Cpath d='M12 2v2'/%3E%3Cpath d='M12 20v2'/%3E%3Cpath d='M2 12h2'/%3E%3Cpath d='M20 12h2'/%3E%3C/svg%3E");
				background-repeat: no-repeat;
				background-position: center;
				background-size: contain;
			  }
			  
			  /* При наведении - цвет #c61a1a */
			  #admin-menu a.icon-task_automation:hover:before,
			  .icon-task_automation:hover:before {
				background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%23c61a1a' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Ccircle cx='12' cy='12' r='10'/%3E%3Cpolyline points='12 6 12 12 16 14'/%3E%3Cpath d='M12 2v2'/%3E%3Cpath d='M12 20v2'/%3E%3Cpath d='M2 12h2'/%3E%3Cpath d='M20 12h2'/%3E%3C/svg%3E");
			  }
			</style>
		  HTML
		end
    end
  end
end