# Hermes + Beads + OMP Codex starter (OpenCode Go)

Стартовый набор для локальной связки: Telegram/Hermes принимает запрос, Beads хранит задачу, OMP с моделью `openai-codex/gpt-6.1-sol` планирует и рецензирует, OpenCode Go (`opencode-go/kimi-k2.7-code:medium`) внутри `omp task` вносит правки в файлы.

Изначальный запрос владельца: «мне другу надо передать этот сетап с обьяснением о нем и на гите ссылка что бы он скачал». Набор готовится локально; публикация на GitHub решается владельцем отдельно.

Сайт с объяснением схемы и списком сервисов: https://eldarabilwapov.github.io/hermes-beads-opencode-starter/

Набор не устанавливает инструменты автоматически. Beads и OMP CLI: open-source инструменты, которые работают локально. Авторизация, подписки и квоты нужны для hosted model providers: OpenCode Go требует собственную подписку и auth, Codex использует выбранный OpenAI entitlement, Hermes маршрутизируется через выбранный вами provider. Beads как локальный трекер задач платной подписки не требует.

## Что внутри

```text
hermes-beads-opencode-starter/
├── README.md
├── MANIFEST.txt
├── scripts/
│   ├── manager-bridge.sh
│   └── check-kit.sh
├── tests/
│   ├── smoke.sh
│   └── live-beads.sh
├── templates/
│   ├── config.yml
│   ├── AGENTS.md
│   └── bridge.env.example
├── skills/
│   └── hermes-beads-manager/
│       └── SKILL.md
└── docs/
    └── VERIFICATION.md
```

- `scripts/manager-bridge.sh`: capture, plan, approve, execute, status.
- `templates/config.yml`: конфигурация OMP с ролями и цепочками fallback.
- `templates/AGENTS.md`: правила корневого Codex: планирование, рецензия, делегирование исполнения агенту `task` на OpenCode Go.
- `templates/bridge.env.example`: переменные окружения для запуска bridge.
- `skills/hermes-beads-manager/SKILL.md`: инструкция для Hermes, если вы встраиваете bridge вручную.
- `docs/VERIFICATION.md`: что и как проверялось, с честными оговорками.

## Архитектура

```text
Telegram owner
    -> Hermes gateway (allowlisted user only)
    -> manager-bridge capture
    -> Beads issue ( durable intent + status )
    -> explicit owner approval for that issue
    -> manager-bridge execute
    -> OMP Codex-led overlay
    -> OpenCode Go executors edit bounded tasks
    -> Codex verifies and accepts the result
    -> run artifact + Beads comments
    -> Hermes returns evidence to Telegram
```

Корневой `openai-codex/gpt-6.1-sol` работает как планировщик, рецензент и оркестратор. Любое изменение файлов он делегирует агенту `omp task` с маршрутом на OpenCode Go. Запреты на commit, push, публикацию, изменение секретов и обход локальных политик: instruction-only правила, а не ограничение файловой системы или недостаток полномочий у инструментов. Bridge физически может писать в `HERMES_STATE_DIR` и в рабочую копию проекта; ограничения задаются конфигурацией, approval и явными политиками владельца.

## Требования

Минимальное окружение, на котором набор проверялся:

- Bash 3.2 или новее (`/bin/bash` 3.2.57 на тестовом хосте).
- Git для создания нового демо-проекта (`git init`) и для скачивания набора.
- Beads CLI (`bd`) и oh-my-pi CLI (`omp`) установлены отдельно.
- Unix-утилиты `mktemp`, `tee`, `grep`, `find`.
- Python 3 со стандартной библиотекой используется только в `scripts/check-kit.sh` и в тестовых двойниках; `scripts/manager-bridge.sh` для канонизации путей Python не требует.

Пройденная тестовая матрица не означает поддержку любых старых CLI или операционных систем. Если ваша версия `bash`, `bd` или `omp` сильно старше протестированных, поведение может отличаться.

`HERMES_STATE_DIR` не должен лежать внутри `HERMES_PROJECT` и не должен находиться внутри каталога starter kit. Безопасное значение по умолчанию: каталог вне проекта, например `$HOME/.local/state/hermes-beads-opencode`.

## Установка и настройка

Автоматические установщики и `curl | bash` не используются. Устанавливайте каждый компонент по официальным инструкциям.

### Скачать набор

```bash
git clone --branch starter-kit https://github.com/eldarabilwapov/hermes-beads-opencode-starter.git
```

Или скачайте ZIP-архив по ссылке: https://github.com/eldarabilwapov/hermes-beads-opencode-starter/archive/refs/heads/starter-kit.zip

### 1. Hermes

- Документация: https://hermes-agent.nousresearch.com/docs/llms.txt
- Установка: https://hermes-agent.nousresearch.com/docs/getting-started/installation
- Настройка безопасности: https://hermes-agent.nousresearch.com/docs/user-guide/security
- Создание навыков: https://hermes-agent.nousresearch.com/docs/developer-guide/creating-skills

Рекомендуемый режим approvals: `manual` или `smart`. Для ручного контроля используйте `mode: manual` и отключите автоматические опасные режимы:

```yaml
approvals:
  mode: manual
  cron_mode: deny
  single_query_mode: deny
  unattended_mode: deny
```

Не включайте `unattended`, `cron` и `single_query` для опасных команд.

### 2. oh-my-pi (OMP)

- Репозиторий: https://github.com/can1357/oh-my-pi
- Настройки: https://raw.githubusercontent.com/can1357/oh-my-pi/main/docs/settings.md

Поддерживаемые режимы approval CLI: `always-ask`, `always-ask-cached`, `write`, `yolo`. Самый безопасный: `always-ask`. Флаг `--plan-yolo` автоматически переключается в исполнение и не подходит для планирования в этом рабочем процессе.

### 3. Beads

- Репозиторий: https://github.com/gastownhall/beads

Для изолированных тестов можно инициализировать проект с `--non-interactive --skip-agents --skip-hooks --prefix <dir>`. Основная настройка делается вручную.

### 4. OpenCode Go

- Документация: https://opencode.ai/docs/console/go/

Требуется отдельная подписка и собственная авторизация. Авторизацию можно выполнить интерактивно через `/login` или picker провайдеров в OMP, либо через личную переменную окружения `OPENCODE_API_KEY` вне репозитория. Не используйте `omp login opencode-go`, если вы не уверены, что провайдер поддерживает такой OAuth-аргумент. Поддержка OMP на стороне OpenCode Go не гарантируется этим набором.

Проверить доступные модели можно после авторизации:

```bash
omp models openai-codex
omp models opencode-go
omp models --no-extensions --config "$HERMES_OMP_CONFIG"
```

## Быстрый старт

Все команды ниже запускаются из распакованного каталога starter kit. Переменная `KIT_DIR` фиксирует абсолютный путь к kit, поэтому source-шаблоны, скрипты и конфигурация остаются доступны даже если вы позже перейдёте в другой cwd.

```bash
KIT_DIR="$(pwd -P)"
```

### 1. Подготовьте конфигурацию OMP

Скопируйте overlay в каталог вне kit. `cp -n` не перезапишет существующий файл, если он уже есть:

```bash
mkdir -p "$HOME/.omp/agent"
cp -n "$KIT_DIR/templates/config.yml" "$HOME/.omp/agent/config-hermes-codex.yml"
```

Отредактируйте пути, роли и модели под свои подписки. Конфиг использует `enabledModels` как allowlist из трёх catalog entries: Codex, Kimi, GLM. `enabledProviders` управляет discovery-источниками, а не выбором модели.

### 2. Подготовьте переменные окружения

Скопируйте пример env в каталог вне kit и отредактируйте:

```bash
mkdir -p "$HOME/.config/hermes-beads"
cp -n "$KIT_DIR/templates/bridge.env.example" "$HOME/.config/hermes-beads/bridge.env"
# отредактируйте $HOME/.config/hermes-beads/bridge.env
source "$HOME/.config/hermes-beads/bridge.env"
```

Минимальный набор переменных:

```bash
export HERMES_PROJECT="$HOME/HermesBeadsDemo/project"
export HERMES_OMP_CONFIG="$HOME/.omp/agent/config-hermes-codex.yml"
export HERMES_STATE_DIR="$HOME/.local/state/hermes-beads-opencode"
# export BD_BIN=/custom/path/to/bd
# export OMP_BIN=/custom/path/to/omp
```

- `HERMES_PROJECT`: абсолютный путь к демо-проекту. Bridge приводит его к каноническому физическому пути.
- `HERMES_OMP_CONFIG`: путь к YAML-конфигу OMP.
- `HERMES_STATE_DIR`: корень состояния вне проекта. Bridge создаёт внутри него `runs/` для артефактов, `approvals/` для одобрений и файл `.owner` с каноническим путём проекта. Не используйте один state dir для нескольких проектов.
- `BD_BIN` и `OMP_BIN` опционны. По умолчанию bridge ищет `bd` и `omp` в переменной `PATH`.

### 3. Создайте новый проект и инициализируйте Beads

Демо-проект создаётся в явно новом каталоге. Если каталог уже существует, команда останавливается, чтобы не перезаписать существующий проект целиком:

```bash
if [ -e "$HERMES_PROJECT" ]; then
  echo "Directory already exists, choose a new HERMES_PROJECT: $HERMES_PROJECT" >&2
  exit 1
fi
mkdir -p "$HERMES_PROJECT"
git -C "$HERMES_PROJECT" init
# Live recipe verified with Beads 1.2.2: run bd init inside the project directory.
# `bd -C <dir>` works for show/comments/create; for init we use this subshell to avoid cwd leak.
( cd "$HERMES_PROJECT" && bd init --quiet --non-interactive --prefix starter --skip-hooks --skip-agents )
```

Флаг `--prefix starter` задаёт валидный префикс для Beads; без него автоматически сгенерированный префикс может содержать пробелы или другие символы, которые `bd init` не принимает.

Если у вас уже есть проект, пропустите `bd init`, но только если в каталоге уже есть `.beads/`. Если `bd init` требует Git-репозиторий, выполните `git -C "$HERMES_PROJECT" init` без commit.

### 4. Установите project AGENTS.md и Hermes skill

Скопируйте шаблоны без перезаписи существующих файлов. Если файлы уже есть, объедините вручную:

```bash
cp -n "$KIT_DIR/templates/AGENTS.md" "$HERMES_PROJECT/AGENTS.md"
mkdir -p "$HOME/.hermes/skills/hermes-beads-manager"
cp -n "$KIT_DIR/skills/hermes-beads-manager/SKILL.md" "$HOME/.hermes/skills/hermes-beads-manager/SKILL.md"
```

Не копируйте весь starter kit bulk в каталог Hermes. Hermes находит skill по пути, который вы указываете вручную; bridge не регистрируется как plugin.

### 5. Добавьте scripts в PATH

В той же shell, из которой запускается Hermes или в которой вы вызываете bridge вручную, добавьте каталог скриптов kit в переменную `PATH`:

```bash
export PATH="$KIT_DIR/scripts:$PATH"
```

Service/gateway Hermes работает в своём окружении; env-переменные и PATH к bridge нужно прописать вручную в способе запуска сервиса, который вы используете сейчас.

### 6. Создайте Beads-задачу

```bash
source "$HOME/.config/hermes-beads/bridge.env"
export PATH="$KIT_DIR/scripts:$PATH"
ISSUE=$(manager-bridge.sh capture \
  --title "Добавить приветствие в README" \
  --request "Друг просит добавить в README проекта одну строчку с приветствием." \
  --acceptance "README.md проекта содержит строку приветствия, smoke.sh проходит.")
echo "$ISSUE"
```

Переменная `ISSUE` содержит реальный идентификатор задачи, например `HERMES-42`. Дальнейшие команды используют эту переменную.

### 7. Составьте план

```bash
manager-bridge.sh plan "$ISSUE"
```

Bridge планирует задачу через OMP. Используются `--tools read,grep,glob`, `--no-session`, `--no-extensions`, `--approval-mode always-ask`, `--model openai-codex/gpt-6.1-sol`, `--thinking high`, `--max-time 20m`. Артефакт плана записывается сюда:

```text
$HERMES_STATE_DIR/runs/<id>-<stamp>-plan-XXXXXX
```

`XXXXXX`: случайный суффикс от `mktemp`. Если планирование завершилось с `rc=0`, bridge создаёт файл метаданных `$HERMES_STATE_DIR/approvals/<id>.plan` с хешами плана, контракта и конфига. `rc=0` не означает, что план идеален. Владелец обязан прочитать артефакт плана перед approve. Не редактируйте файл `.plan` вручную.

### 8. Одобрите выполнение

```bash
manager-bridge.sh approve "$ISSUE" --by "local:owner"
```

`local:owner`: валидный owner id. Вместо `local:<name>` можно указать `telegram:<id>`, где `<id>` должен быть реальным идентификатором Telegram.

Approve требует наличия файла метаданных `$HERMES_STATE_DIR/approvals/<id>.plan`. Если конфиг или контракт задачи изменились после планирования, approve отклонится и нужно будет перепланировать. Receipt пишется атомарно: сначала во временный файл, затем добавляется комментарий в Beads, и только потом receipt перемещается на финальное место `$HERMES_STATE_DIR/approvals/<id>`. Если комментарий или audit не прошли, receipt не публикуется.

Bridge обновляет Beads только через `bd comments add`, чтобы собственные записи не инвалидировали approval.

### 9. Выполните задачу

```bash
manager-bridge.sh execute "$ISSUE"
```

Bridge передаёт задачу на исполнение в OMP. Используются `--approval-mode always-ask`, `--wait-async`, `--model openai-codex/gpt-6.1-sol`, `--thinking high`, `--max-time 2h`. Артефакт выполнения записывается сюда:

```text
$HERMES_STATE_DIR/runs/<id>-<stamp>-execute-XXXXXX
```

`XXXXXX`: случайный суффикс от `mktemp`.

### 10. Проверьте статус

```bash
manager-bridge.sh status "$ISSUE"
```

Команда показывает задачу из Beads, пути к артефактам, статус approval и сводку по receipt. Она не выводит текущие метаданные `.plan`. State directory получает owner marker `$HERMES_STATE_DIR/.owner` с каноническим путем проекта. Если marker не совпадает с текущим `HERMES_PROJECT`, bridge отклоняет любую мутацию до исправления.

## Практические примеры с пробелами в путях

```bash
export HERMES_PROJECT="$HOME/My Projects/acme"
export HERMES_STATE_DIR="$HOME/Library/Application Support/hermes-beads"
export HERMES_OMP_CONFIG="$HOME/My Configs/hermes-codex.yml"
export PATH="$KIT_DIR/scripts:$PATH"

manager-bridge.sh capture \
  --title "Пример с пробелами" \
  --request "Проверить, что bridge корректно работает с путями, содержащими пробелы." \
  --acceptance "Скрипт не падает на mkdir, bd create, omp plan."
```

## Безопасность и ограничения

Политики ниже описывают намерения и настройки. Они не создают песочницу и не заменяют проверку человеком.

- Bridge не коммитит, не пушит и не мёржит.
- Bridge не удаляет файлы проекта. Это instruction-only политика для модели. Bridge может инвалидировать собственные receipt в `HERMES_STATE_DIR`, если задача, план или конфиг изменились.
- Bridge не меняет production-секреты и не выполняет деструктивных операций с базами данных.
- Approval receipt: это техническое средство учёта, а не криптографическая защита. Пользователь, который может писать в `HERMES_STATE_DIR`, может подделать receipt.
- Инструкции и промпты не создают security boundary. В headless CLI-подагенты OMP ведут себя как `yolo` независимо от настроек. Bridge предпочитает `always-ask`, но не может полностью контролировать поведение подагентов.
- Режим `always-ask` в headless-исполнении может заблокировать мутации, потому что подагент не получит prompt для одобрения. В интерактивном OMP с `always-ask` человек может одобрить каждый `task`-вызов после review.
- Код возврата 0 у `omp` или `manager-bridge.sh` не доказывает, что задача выполнена. Проверяйте артефакты, diff и smoke/live тесты.
- Hermes skill не встроен как штатный плагин. Telegram pairing и allowlist настраиваются вручную владельцем.
- Approval выдаётся только после явного согласия конкретного владельца (`approve --by`). Bridge не генерирует approval самостоятельно.
- Этот набор не гарантирует автоматическую реализацию из коробки. Успех зависит от авторизации, квот, доступности моделей и правильной настройки окружения.
- Не предлагайте `yolo` или auto-approve в качестве обхода. Если `always-ask` мешает автоматизации, решение принимает владелец вручную.

## Проверки

Скрипты проверки:

- `tests/smoke.sh`: CLI doubles без реального провайдера; 43 проверки PASS, 0 FAIL.
- `scripts/check-kit.sh`: проверяет структуру набора по `MANIFEST.txt`: 11 файлов, content patterns и архив.
- `tests/live-beads.sh`: требует реального `bd` и изолированного тестового проекта Beads; исполняет capture, plan, approve и execute в минимальном режиме с OMP double; 11 проверок PASS, 0 FAIL.

Подробнее о методах и текущем статусе верификации см. `docs/VERIFICATION.md`.

## Поддерживаемые платформы

Целевые платформы: macOS, Linux, WSL2. Протестирован только один хост; этот список не означает поддержку любых старых CLI или окружений.

Точно известный тестовый хост:

- macOS 27.2, build 26B123, arm64
- `/bin/bash` 3.2.57(1)-release
- `omp` 18.18.0
- `bd` 1.2.2 (6c124203e main)
- `hermes --version`: Hermes Agent v0.23.0 (2026.9.24), stable

Проверки на чистой установке у друга, на Linux и WSL2, с реальным Hermes gateway, live-провайдером и Telegram не выполнялись. Детали: `docs/VERIFICATION.md`.

## Источники

- Hermes docs: https://hermes-agent.nousresearch.com/docs/llms.txt
- Hermes installation: https://hermes-agent.nousresearch.com/docs/getting-started/installation
- Hermes security: https://hermes-agent.nousresearch.com/docs/user-guide/security
- Hermes skills: https://hermes-agent.nousresearch.com/docs/developer-guide/creating-skills
- oh-my-pi: https://github.com/can1357/oh-my-pi
- oh-my-pi settings: https://raw.githubusercontent.com/can1357/oh-my-pi/main/docs/settings.md
- Beads: https://github.com/gastownhall/beads
- OpenCode Go: https://opencode.ai/docs/console/go/
