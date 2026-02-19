# ============================================================================
# Файл: app/models/task_automation.rb
# Назначение: Модель-фасад для доступа к функционалу автоматизации задач
# ============================================================================

class TaskAutomation < ActiveRecord::Base
  # ============================================================================
  # Подключение модуля конфигурации
  # ============================================================================
  include TaskAutomation::Configuration
  
  # ============================================================================
  # Константы (теперь используются из Configuration)
  # ============================================================================
  # LOG_FILE_PATH и LOG_MAX_SIZE берутся из Configuration
  
  # ============================================================================
  # Основной метод запуска обработки задач
  # ============================================================================
  def self.process
    # Создание нового экземпляра процессора для обработки
    processor = TaskAutomation::TaskProcessor.new
    
    # Запуск процесса обработки и получение результатов
    result = processor.process
    
    # Отправка уведомлений об ошибках, если они были зафиксированы
    send_error_notifications if processor.has_errors?
    
    # Возврат структурированного результата выполнения
    result
  end
  
  # ============================================================================
  # Метод получения настроек плагина из таблицы settings
  # ============================================================================
  def self.get_settings
    # Получение всех настроек плагина через стандартный механизм Redmine
    settings = Setting.plugin_redmine_task_automation
    
    # Возврат настроек с значениями по умолчанию для отсутствующих ключей
    {
      source_project_id: settings['source_project_id'].to_i,
      author_id: settings['author_id'].to_i,
      tracker_id: settings['tracker_id'].to_i,
      error_notification_email: settings['error_notification_email']
    }
  end
  
  # ============================================================================
  # Метод получения ID кастомного поля по его названию
  # ============================================================================
  def self.get_custom_field_id_by_name(field_name)
    # Поиск кастомного поля в базе данных по имени (нечувствительно к регистру)
    custom_field = CustomField.find_by(name: field_name, field_format: 'string')
    
    # Если не найдено как строка, пробуем другие форматы
    custom_field ||= CustomField.find_by(name: field_name)
    
    # Возврат ID поля или nil, если поле не найдено
    custom_field&.id
  end
  
  # ============================================================================
  # Метод получения всех кастомных полей плагина с их ID
  # Возвращает хэш: { 'Название поля' => ID }
  # ============================================================================
  def self.get_all_custom_fields_with_ids
    # Инициализация хэша для результатов
    fields_with_ids = {}
    
    # Перебор всех необходимых полей из конфигурации
    TaskAutomation::Configuration::REQUIRED_CUSTOM_FIELDS.each do |field_name|
      # Получение ID поля и сохранение в хэш
      fields_with_ids[field_name] = get_custom_field_id_by_name(field_name)
    end
    
    # Возврат хэша с названиями и ID
    fields_with_ids
  end
  
  # ============================================================================
  # Метод проверки наличия всех необходимых кастомных полей
  # Возвращает массив отсутствующих полей
  # ============================================================================
  def self.check_missing_custom_fields
    # Массив для хранения отсутствующих полей
    missing_fields = []
    
    # Перебор всех необходимых полей из конфигурации
    TaskAutomation::Configuration::REQUIRED_CUSTOM_FIELDS.each do |field_name|
      # Получение ID поля
      field_id = get_custom_field_id_by_name(field_name)
      
      # Если поле не найдено, добавление в массив отсутствующих
      missing_fields << field_name unless field_id.present?
    end
    
    # Возврат массива отсутствующих полей
    missing_fields
  end
  
  # ============================================================================
  # Метод записи сообщения в журнал логирования
  # ============================================================================
  def self.log_message(level, message, issue_id = nil)
    # Формирование временной метки в формате YYYY-MM-DD HH:MM:SS
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    
    # Формирование строки лога с уровнем, ID задачи (если есть) и сообщением
    log_entry = "[#{timestamp}] [#{level.upcase}]"
    log_entry += " [Issue ##{issue_id}]" if issue_id
    log_entry += " #{message}"
    
    # Проверка размера файла журнала для ротации
    rotate_log_file if File.exist?(LOG_FILE_PATH) && File.size(LOG_FILE_PATH) > LOG_MAX_SIZE
    
    # Директория для файла журнала (создаётся, если не существует)
    log_dir = File.dirname(LOG_FILE_PATH)
    FileUtils.mkdir_p(log_dir) unless File.directory?(log_dir)
    
    # Запись сообщения в файл журнала с добавлением новой строки
    File.open(LOG_FILE_PATH, 'a') { |f| f.puts(log_entry) }
  end
  
  # ============================================================================
  # Метод ротации файла журнала при превышении максимального размера
  # ============================================================================
  def self.rotate_log_file
    # Формирование имени файла для архива с временной меткой
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    rotated_file = "#{LOG_FILE_PATH}.#{timestamp}"
    
    # Перемещение текущего файла журнала в архив
    File.rename(LOG_FILE_PATH, rotated_file) if File.exist?(LOG_FILE_PATH)
  end
  
  # ============================================================================
  # Метод отправки уведомлений об ошибках на электронную почту
  # ============================================================================
  def self.send_error_notifications
    # Получение email для уведомлений из настроек плагина
    email = get_settings[:error_notification_email]
    
    # Проверка наличия email для отправки
    return if email.blank?
    
    # Чтение всех записей уровня error из журнала за текущий сеанс
    error_messages = read_error_logs
    
    # Проверка наличия ошибок для отправки
    return if error_messages.empty?
    
    # Формирование темы письма с количеством ошибок и временной меткой
    subject = I18n.t('task_automation.email.error_subject', 
                     count: error_messages.count,
                     date: Time.now.strftime('%Y-%m-%d %H:%M'))
    
    # Формирование тела письма со списком всех ошибок
    body = I18n.t('task_automation.email.error_body', 
                  errors: error_messages.join("\n"))
    
    # Отправка письма через стандартную почтовую систему Redmine
    begin
      Mailer.deliver_now(
        to: email,
        subject: subject,
        body: body
      )
    rescue => e
      # Логирование ошибки отправки письма
      log_message('error', I18n.t('task_automation.log.email_send_failed', error: e.message))
    end
  end
  
  # ============================================================================
  # Метод чтения записей об ошибках из журнала
  # ============================================================================
  def self.read_error_logs
    # Проверка существования файла журнала
    return [] unless File.exist?(LOG_FILE_PATH)
    
    # Массив для хранения сообщений об ошибках
    errors = []
    
    # Получение текущей даты для фильтрации записей за сегодня
    today = Date.today.strftime('%Y-%m-%d')
    
    # Чтение файла журнала построчно
    File.foreach(LOG_FILE_PATH) do |line|
      # Проверка, что запись содержит уровень ERROR и относится к текущей дате
      if line.include?('[ERROR]') && line.start_with?("[#{today}")
        # Извлечение сообщения об ошибке (после уровня логирования)
        error_message = line.split('[ERROR]').last&.strip
        errors << error_message if error_message.present?
      end
    end
    
    # Возврат массива сообщений об ошибках
    errors
  end
  
  # ============================================================================
  # Метод проверки существования проекта по ID
  # ============================================================================
  def self.project_exists?(project_id)
    # Проверка наличия проекта в базе данных
    Project.exists?(project_id)
  end
  
  # ============================================================================
  # Метод проверки существования трекера в проекте
  # ============================================================================
  def self.tracker_exists_in_project?(project_id, tracker_id)
    # Получение проекта
    project = Project.find_by(id: project_id)
    return false unless project
    
    # Проверка наличия трекера в списке доступных для проекта
    project.trackers.exists?(tracker_id)
  end
  
  # ============================================================================
  # Метод проверки существования группы пользователей
  # ============================================================================
  def self.group_exists?(group_name)
    # Поиск группы по имени (нечувствительно к регистру)
    Group.exists?(name: group_name)
  end
  
  # ============================================================================
  # Метод проверки, можно ли группе назначать задачи в проекте
  # ============================================================================
  def self.group_can_be_assigned?(group_name, project_id)
    # Поиск группы по имени
    group = Group.find_by(name: group_name)
    return false unless group
    
    # Получение проекта
    project = Project.find_by(id: project_id)
    return false unless project
    
    # Проверка наличия роли с правом назначения задач
    member = Member.find_by(project: project, principal: group)
    return false unless member
    
    # Проверка наличия роли с правом работы с задачами
    member.roles.any? { |role| role.permissions.include?(:edit_issues) }
  end
  
  # ============================================================================
  # Метод получения группы по имени
  # ============================================================================
  def self.get_group_by_name(group_name)
    # Поиск группы в базе данных
    Group.find_by(name: group_name)
  end
  
  # ============================================================================
  # Метод проверки, является ли день рабочим
  # Использует общие настройки Redmine о рабочих днях
  # ============================================================================
  def self.working_day?(date)
    # Получение дня недели (0 = воскресенье, 6 = суббота)
    wday = date.wday
    
    # Проверка настроек рабочих дней в Redmine
    # Setting.working_days содержит массив рабочих дней недели
    working_days = Setting.working_days || [1, 2, 3, 4, 5]
    
    # Возврат true, если день недели есть в списке рабочих
    working_days.include?(wday)
  end
  
  # ============================================================================
  # Метод сдвига даты на рабочие дни
  # ============================================================================
  def self.shift_to_working_day(date, direction: :forward)
    # Копирование даты для избежания изменения оригинала
    result_date = date.clone
    
    # Цикл сдвига до нахождения рабочего дня
    while !working_day?(result_date)
      if direction == :forward
        # Сдвиг вперёд на один день
        result_date += 1.day
      else
        # Сдвиг назад на один день
        result_date -= 1.day
      end
    end
    
    # Возврат скорректированной даты
    result_date
  end
end