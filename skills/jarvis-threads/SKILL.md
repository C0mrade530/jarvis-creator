---
name: jarvis-threads
description: Настройка Threads Content Factory, подключение своего аккаунта Threads через Upload-Post, подготовка постов, согласование очереди и проверка статуса публикаций.
---

# Threads Content Factory

Jarvis подключает закреплённую версию репозитория. Из исходной папки Jarvis выполните:

```sh
./jarvis threads install
./jarvis threads setup
./jarvis threads run
```

Для установки нужны Git и uv. Команда setup спрашивает ключ Upload-Post в локальном терминале. В другом терминале откройте чат с инструментами:

```sh
./jarvis threads chat --agent codex
./jarvis threads chat --agent claude
```

Выберите один вариант. API и очередь работают, пока открыт терминал с `threads run`. Для постоянной работы используйте развёртывание из документации репозитория.

1. Прочитайте статус через `get_factory_status`.
2. По запросу человека получите ссылку через `start_threads_connection`. Вход и согласие на доступ выполняет сам владелец аккаунта в браузере. Не просите пароль, одноразовый код, cookie или ключ в чате.
3. Проверьте `check_threads_connection`, покажите фактическое имя аккаунта и привяжите его через `confirm_threads_account` после подтверждения владельца.
4. Покажите конкретные тексты и расписание. Используйте `queue_approved_posts` после согласования текстов. Автогенерацию будущих постов включайте после отдельного согласия на аккаунт, время и режим.
5. Статус опубликованного поста сверяйте с очередью и ссылкой. Для остановки применяйте `pause_publishing` по запросу владельца.

Встроенный голосовой чат Jarvis подсказывает команды. Управление публикациями доступно в отдельном чате, запущенном через `threads chat`.

[Подключение аккаунта и MCP](https://github.com/C0mrade530/threads-content-factory/blob/0d15e232d9ad727cc9e24456deabb486f6c33451/docs/CONNECT_CHAT.md) · [Развёртывание](https://github.com/C0mrade530/threads-content-factory/blob/0d15e232d9ad727cc9e24456deabb486f6c33451/docs/DEPLOY.md)
