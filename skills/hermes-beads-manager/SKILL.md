---
name: hermes-beads-manager
description: Accept owner requests from Telegram, create Beads issues, and drive the local manager-bridge.sh workflow.
---

# hermes-beads-manager

Skill для ручной интеграции Hermes с локальным bridge `manager-bridge.sh`. Этот skill не встроен в Hermes как штатный плагин и не устанавливается автоматически.

## Что делает

- Принимает запрос владельца из Telegram.
- Создаёт задачу в Beads через `manager-bridge.sh capture`.
- Запускает планирование через `manager-bridge.sh plan`.
- После явного согласия владельца запускает `manager-bridge.sh execute`.
- Возвращает владельцу артефакты и статус.

## Что НЕ делает

- Не генерирует approval самостоятельно. Одобрение даёт только конкретный владелец (`approve --by "local:owner"` для локального режима или `telegram:<id>` для Telegram).
- Не коммитит, не пушит, не публикует и не удаляет файлы.
- Не меняет production-секреты и не выполняет деструктивных операций.
- Не считает receipt или project instructions security boundary.

## Настройка вручную

1. Пропиши Telegram pairing и allowlist пользователей в конфигурации Hermes.
2. Убедись, что `manager-bridge.sh` видит три переменные: `HERMES_PROJECT`, `HERMES_OMP_CONFIG`, `HERMES_STATE_DIR`. Источник: `$HOME/.config/hermes-beads/bridge.env` или другое внешнее env.
3. Скопируй этот skill в каталог навыков Hermes. Указывай полный абсолютный путь к `manager-bridge.sh` в командах, либо добавь `$KIT_DIR/scripts` в `PATH` той shell, откуда запускаешь Hermes. Service/gateway Hermes работает в своём окружении; env и PATH к bridge нужно прописать вручную в способе запуска сервиса.
4. Проверь `capture` и `status` на тестовой задаче до первого реального запуска.

Skill не регистрируется как plugin и не изобретает собственный approval. Выполнение начинается только после явного одобрения конкретным владельцем конкретного issue и плана.

## Пример запроса владельцу

```text
Новая задача HERMES-7: добавить приветствие в README.
План сохранён в $HERMES_STATE_DIR/runs/HERMES-7-20261108T120000Z-plan.txt.
Одобри выполнение, если план выглядит корректно.
```

## Пример одобрения

```bash
manager-bridge.sh approve HERMES-7 --by "local:owner"
```

`local:owner`: валидный owner id. Вместо `local:<name>` можно указать `telegram:<id>`, где `<id>` должен быть реальным идентификатором Telegram. Только после этого bridge может запустить `execute`.
