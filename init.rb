# Подключение модуля в ядро приложения (устанавливает безопасный контекст загрузки)
Redmine::Plugin.register :redmine_task_automation do

	# Название модуля, отображается в списке плагинов и на странице настроек
	name 'Redmine Task Automation'

	# Автор модуля
	author 'Андрей Якушев'

	# Описание функционала модуля
	description 'Периодическое создание задач в рабочих проектах по специальным шаблонам - задачам определённого формата в определённом проекте.'

	# Версия модуля (следует за версией приложения)
	version '1.0.0'

	# Ссылка на официальную страницу или репозиторий модуля
	url 'https://github.com/selfauthor/redmine-task-automation'

	# Минимальная версия ядра, необходимая для работы модуля
	requires_redmine version_or_higher: '6.0.0'

	# Настройки модуля, хранящиеся в стандартной таблице `settings`
	settings(
		# Значения по умолчанию для настроек
		default: {
			'source_project_id' => '',			# ID проекта-источника с шаблонами задач
			'author_id' => '',					# ID автора задачи
			'tracker_id' => ''					# ID трэкера, задачи которого нужно проверять на текущую актуальность
		},
		# Опционально: путь к кастомному представлению формы настроек
		# Если не указано — Redmine сгенерирует форму автоматически
		# partial: 'settings/task_automation_settings'
	)

	# Добавление пункта меню в административном разделе (опционально)
	# Если нужно отдельное меню, а не только страница настроек
	# menu :admin_menu, :task_automation_settings,
	#	{ controller: 'task_automation_settings', action: 'index' },
	#	caption: :label_task_automation_settings,
	#	after: :plugins,
	#	html: { class: 'task-automation-settings' }

end

# Подключение дополнительных файлов (если они есть)
# require_dependency 'task_automation/task_processor'