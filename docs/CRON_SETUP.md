# Настройка автоматического запуска через cron

## Что такое cron?

**cron** — это системная служба в Linux/Unix для выполнения задач по расписанию.

## Настройка cron для плагина

### Шаг 1: Откройте crontab

```bash
crontab -e
```

### Шаг 2: Добавьте задачу

Вставьте следующую строку:

```bash
0 8 * * * cd /var/www/redmine; bundle exec rake redmine:task_automation:process RAILS_ENV=production >> /var/www/cronlog/task_automation.log 2>&1
```

### Расшифровка параметров

| Параметр | Значение | Описание |
|----------|----------|----------|
| `0 8 * * *` | Время запуска | 8:00 ежедневно. Можно изменить на любое желаемое время |
| `cd /var/www/redmine;` | Переход в папку | Рабочая директория Redmine |
| `bundle exec rake` | Запуск оболочки | Выполнение rake-задачи |
| `redmine:task_automation:process` | Команда плагина | Запуск процесса обработки задач |
| `RAILS_ENV=production` | Режим Redmine | Режим работы (production/development) |
| `>> /var/www/cronlog/task_automation.log` | Лог cron | Журнал сообщений cron |
| `2>&1` | Перенаправление ошибок | Ошибки записываются в тот же лог |

## Формат времени cron

```
* * * * *
│ │ │ │ │
│ │ │ │ └─ День недели (0-7, 0 и 7 = воскресенье)
│ │ │ └─── Месяц (1-12)
│ │ └───── День месяца (1-31)
│ └─────── Час (0-23)
└───────── Минута (0-59)
```

### Примеры расписаний

| Расписание | Значение |
|------------|----------|
| `0 8 * * *` | Каждый день в 8:00 |
| `0 9 * * 1` | Каждый понедельник в 9:00 |
| `0 8 1 * *` | 1-го числа каждого месяца в 8:00 |
| `0 8 * * 1-5` | Каждый рабочий день в 8:00 |
| `0 8,12,17 * * *` | Каждый день в 8:00, 12:00 и 17:00 |

## Создание директории для логов

```bash
mkdir -p /var/www/cronlog
chown www-data:www-data /var/www/cronlog
chmod 755 /var/www/cronlog
```

## Проверка работы cron

### Просмотр установленных задач

```bash
crontab -l
```

### Просмотр логов cron

```bash
tail -f /var/www/cronlog/task_automation.log
```

### Тестовый запуск

Для проверки можно запустить задачу вручную:

```bash
cd /var/www/redmine
bundle exec rake redmine:task_automation:process RAILS_ENV=production
```

## Типовые ошибки

### Ошибка: bundle: command not found

**Решение:** Укажите полный путь к bundle:

```bash
0 8 * * * cd /var/www/redmine; /opt/ruby-3.2/bin/bundle exec rake redmine:task_automation:process RAILS_ENV=production >> /var/www/cronlog/task_automation.log 2>&1
```

### Ошибка: Permission denied

**Решение:** Проверьте права доступа:

```bash
chown -R www-data:www-data /var/www/redmine
```

### Задача не выполняется

**Проверьте:**
1. Запущен ли cron: `service cron status`
2. Права на выполнение: `chmod +x /var/www/redmine/script/rails`
3. Логи системы: `grep CRON /var/log/syslog`

## Перезапуск cron

После изменения crontab:

```bash
service cron restart
```

или

```bash
systemctl restart cron
```

## Отключение автоматического запуска

Закомментируйте строку в crontab (добавьте `#` в начало):

```bash
# 0 8 * * * cd /var/www/redmine; bundle exec rake redmine:task_automation:process RAILS_ENV=production >> /var/www/cronlog/task_automation.log 2>&1
```

---

**См. также:** [Логирование](LOGGING.md)