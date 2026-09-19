# Миграция существующей sandbox-инфраструктуры

> **Статус:** `deploy/migrate.sh` и `update-infra.sh` реализованы и покрыты тестами (`tests/test_migrate.sh`, `tests/test_update_infra.sh`) на слепке старой раскладки во временном каталоге. На реальном VPS ничего из описанного здесь ещё не выполнялось.

**Цель:** перевести уже развёрнутый VPS (bare-репозитории, живые проекты, работающий Caddy) на новую раскладку каталогов, атомарные релизы и пер-проектный конфиг — без потери данных, с возможностью полного отката.

**Исходная точка:** инфраструктура из коммита `f84cf38` («Add stop/remove commands for tearing down a project»).

**Принятые решения:**

- Существующие plain-static проекты **не переезжают** на `public/`. Миграция генерирует для каждого из них серверный конфиг с `publish_dir: "."`, полностью сохраняя текущее поведение. Переход на `public/` — отдельная добровольная операция по одному проекту (см. «Пост-миграция»).
- Результат — идемпотентный скрипт `migrate.sh` (с `--dry-run`) плюс этот runbook с ручными эквивалентами каждой команды.
- Короткий простой (единицы минут) допустим. Порядок шагов линейный, без сосуществования старой и новой раскладок.

---

## Глобальные ограничения

Копируются дословно и действуют на всех фазах.

- Все пути к проектам живут строго внутри `/srv/git`, `/srv/apps`, `/srv/sites`, `/srv/state`. Ничего за их пределами миграция не трогает.
- Валидное имя проекта: `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` (1–63 символа, строчная ASCII, первый и последний символ — буква или цифра).
- Серверные `.env` и данные приложений (в т.ч. docker volumes и bind-mount каталоги) не удаляются ни на одном шаге.
- Docker-проекты **не меняют путь рабочего каталога**: он остаётся `/srv/apps/<name>`. Причина — compose выводит имя проекта из basename каталога, и переезд осиротил бы существующие контейнеры и volumes с префиксом `<name>_`.
- Все `rm -rf` в миграции выполняются только по путям, прошедшим проверку «resolved-путь внутри разрешённого корня и не равен самому корню».
- Каждая деструктивная фаза предваряется бэкапом, у каждой фазы есть описанный откат.

---

## Целевая раскладка

```
/srv/git/<name>.git/                bare-репозиторий (не меняется)
    hooks/post-receive              симлинк → /srv/deploy/hook.sh

/srv/apps/<name>/                   рабочий каталог ТОЛЬКО Docker-проектов
                                    (compose project dir, COMPOSE_PROJECT_NAME=<name>)

/srv/state/<name>/                  НОВОЕ: серверное состояние проекта
    config                          пер-проектный конфиг (см. ниже)
    env                             серверные секреты, подкладываются в сборку
    deploys.tsv                     история: ts, ref, sha, outcome, duration
    releases.tsv                    порядок успешных релизов (откат и ротация)
    logs/<sha>.log                  лог сборки конкретного коммита
    build/                          одноразовое дерево сборки статики (чистится)

/srv/sites/<name>/                  НОВОЕ: релизы статики
    releases/<sha>[.<suffix>]/      собранный вывод (отдельная попытка сборки)
    current -> releases/<sha>       ОТНОСИТЕЛЬНЫЙ симлинк

/srv/state/.locks/<name>.lock       постоянный lock, переживает remove

/srv/caddy/
    Caddyfile                       правится update-скриптом только после бэкапа
    spa.d/<name>.caddy              пер-проектные SPA-правила
    .env                            не трогается
```

Ключевые отличия от текущего состояния:

| Было | Стало |
|---|---|
| `/srv/sites/<name>/index.html` | `/srv/sites/<name>/current/index.html`, `current` → `releases/<sha>` |
| `/srv/apps/<name>` — рабочее дерево всех типов проектов | только Docker; статика собирается в `/srv/state/<name>/build` |
| тип проекта угадывается по файлам при каждом деплое | фиксирован в `/srv/state/<name>/config` |
| `root /srv/sites/{re.app.1}` | `root /srv/sites/{re.app.1}/current` |
| состояния деплоя нет | `deploys.tsv` + `logs/<sha>.log` |

### Формат пер-проектного конфига

`/srv/state/<name>/config` — построчные `KEY=value`, читается только через явный парсинг ключей (не `source`):

```sh
type=static          # static | node | docker
publish_dir=.        # относительно корня репозитория
build_cmd=           # пусто для type=static
spa=false            # true включает fallback на index.html
health_url=          # опционально, для docker: URL проверки готовности
```

Значения, которые генерирует миграция для уже существующих проектов:

- plain static → `type=static`, `publish_dir=.`, `spa=false`
- node с `dist/` → `type=node`, `publish_dir=dist`, `build_cmd=npm run build`
- node с `build/` → `type=node`, `publish_dir=build`, `build_cmd=npm run build`
- docker → `type=docker`, `publish_dir=` (не применяется)

`publish_dir=.` для существующих статических проектов — сознательное сохранение обратной совместимости, а не рекомендуемый дефолт. Для новых проектов дефолт — `public/`.

---

## Предусловия

Выполнить до начала. Если любой пункт не выполнен — миграцию не начинать.

- [ ] Разделы 1–4 улучшений реализованы, ShellCheck и тесты в репозитории зелёные локально.
- [ ] Есть SSH-доступ на VPS под `deploy` и возможность получить root (`sudo`).
- [ ] Снапшот диска VPS в панели Timeweb сделан **сегодня**. Это единственный настоящий откат для Docker-volumes; всё остальное ниже — откат на уровне файлов.
- [ ] Локально известен коммит, на который откатываемся: `f84cf38`.
- [ ] Ни один `git push prod main` не идёт прямо сейчас и никто не будет пушить во время окна.

---

## Фаза 0. Инвентаризация и аудит

Ничего не меняет. Цель — получить список проектов и заранее найти те, что потребуют ручного вмешательства.

**Команда (скрипт):**

```sh
sudo /srv/deploy/migrate.sh audit
```

**Ручной эквивалент:**

```sh
# Список проектов и их тип
for repo in /srv/git/*.git; do
    name=$(basename "$repo" .git)
    work="/srv/apps/$name"
    site="/srv/sites/$name"
    kind="unknown"
    if   [ -f "$work/docker-compose.yml" ] || [ -f "$work/compose.yml" ]; then kind="docker"
    elif [ -f "$work/Dockerfile" ];                                      then kind="dockerfile-only"
    elif [ -f "$work/package.json" ];                                    then kind="node"
    elif [ -d "$site" ];                                                 then kind="static"
    fi
    printf '%-24s %-16s site=%s work=%s\n' "$name" "$kind" \
        "$([ -d "$site" ] && echo yes || echo no)" \
        "$([ -d "$work" ] && echo yes || echo no)"
done

# Имена, не проходящие новую валидацию
for repo in /srv/git/*.git; do
    name=$(basename "$repo" .git)
    printf '%s' "$name" | grep -qE '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' \
        || echo "INVALID NAME: $name"
done

# Node-проекты: какой каталог сборки реально используется
for work in /srv/apps/*/; do
    [ -f "$work/package.json" ] || continue
    echo "$work: dist=$([ -d "$work/dist" ] && echo yes || echo no) build=$([ -d "$work/build" ] && echo yes || echo no)"
done

# Симлинки внутри публикуемой статики — потенциальный выход за пределы каталога
find /srv/sites -maxdepth 3 -type l -printf '%p -> %l\n'

# Секреты, которые сейчас могут публиковаться из корня репозитория
find /srv/sites -maxdepth 2 \( -name '.env*' -o -name '*.pem' -o -name '*.key' -o -name '.git' \) -print
```

**Что зафиксировать в блокноте до перехода дальше:**

1. Полный список проектов с типом.
2. Проекты с невалидными именами → обрабатываются в фазе 1, требуют смены remote на локальной машине.
3. `dockerfile-only` проекты → после исправления детекта Docker они начнут падать с внятной ошибкой вместо молчаливого `docker compose up`. Нужно решение по каждому: добавить `docker-compose.yml` или перевести в другой тип.
4. Node-проекты, где `publish_dir` не `dist` → в конфиг пойдёт `build`.
5. Найденные секреты в `/srv/sites/*` → это уже опубликованные файлы. Они останутся доступны до следующего деплоя проекта: миграция переносит содержимое раздачи как есть, ничего из него не вычищая. После первого же деплоя `.env`, `.git`, `*.pem` и `*.key` в раздачу больше не попадут — они исключаются при публикации даже при `publish_dir=.`. А вот исходники и прочее содержимое репозитория при `publish_dir=.` продолжат публиковаться, и это чинится только переходом на `public/`.

   Если секрет уже утёк, считай его скомпрометированным и меняй, а не просто убирай из раздачи.

---

## Фаза 1. Имена проектов

Выполняется **только** если фаза 0 нашла невалидные имена. Если не нашла — сразу к фазе 2.

Переименование — единственная операция миграции, требующая действий на локальной машине.

```sh
# На VPS, для проекта OldName → new-name
OLD=OldName
NEW=new-name

mv "/srv/git/$OLD.git" "/srv/git/$NEW.git"
[ -d "/srv/apps/$OLD" ]  && mv "/srv/apps/$OLD"  "/srv/apps/$NEW"
[ -d "/srv/sites/$OLD" ] && mv "/srv/sites/$OLD" "/srv/sites/$NEW"
```

Для Docker-проекта после переименования каталога compose перестанет находить старые контейнеры (имя проекта менялось вместе с basename). Поэтому Docker-проект переименовывается так:

```sh
cd "/srv/apps/$OLD" && docker compose down          # ДО переименования, volumes сохраняются
# ... mv как выше ...
cd "/srv/apps/$NEW" && COMPOSE_PROJECT_NAME="$OLD" docker compose up -d
# volumes остаются под старым префиксом OLD_*; чтобы не тащить это дальше,
# зафиксировать COMPOSE_PROJECT_NAME=OLD в /srv/state/<new>/config после фазы 2
```

Затем локально, в репозитории проекта:

```sh
git remote set-url prod ssh://deploy@sandbox.<домен>/srv/git/new-name.git
```

И обновить DNS/лейблы, если поддомен был завязан на старое имя.

---

## Фаза 2. Состояние проектов и конфиги

Создаёт `/srv/state/<name>/` и генерирует конфиги. Не деструктивно: если что-то пойдёт не так, достаточно удалить `/srv/state`.

**Команда:**

Скрипт назначает владельца `deploy:deploy` новым каталогам и файлам.
Повторный запуск исправляет владельцев каталогов от прежней миграции.
Обновляй скрипты только после завершения всех старых операций: путь
блокировки перенесён из `<name>/lock` в `.locks/<name>.lock`.

```sh
sudo /srv/deploy/migrate.sh state --dry-run   # сначала посмотреть, что будет сделано
sudo /srv/deploy/migrate.sh state
```

**Что делает (ручной эквивалент для одного проекта):**

```sh
NAME=myapp
install -d -o deploy -g deploy -m 755 "/srv/state/$NAME" "/srv/state/$NAME/logs"

# определить тип так же, как в фазе 0, и записать конфиг
cat > "/srv/state/$NAME/config" <<'EOF'
type=static
publish_dir=.
build_cmd=
spa=false
health_url=
EOF
chown deploy:deploy "/srv/state/$NAME/config"

# перенести существующий серверный .env, если он был положен руками в рабочий каталог
if [ -f "/srv/apps/$NAME/.env" ] && [ ! -e "/srv/state/$NAME/env" ]; then
    cp -a "/srv/apps/$NAME/.env" "/srv/state/$NAME/env"
fi

install -d -o deploy -g deploy /srv/state/.locks
: > "/srv/state/.locks/$NAME.lock"
chown deploy:deploy "/srv/state/.locks/$NAME.lock"
```

Важно: `.env` именно **копируется**, а не перемещается. Docker-проекты продолжают читать `/srv/apps/<name>/.env` до конца миграции, и при откате он остаётся на месте.

**Проверка:**

```sh
for d in /srv/state/*/; do echo "== $d"; cat "$d/config"; done
```

Ожидание: у каждого проекта из фазы 0 есть конфиг с корректным `type` и `publish_dir`.

**Откат фазы 2:** `sudo rm -rf /srv/state` (каталог создан миграцией, ничего исходного в нём нет — `env` там копия).

---

## Фаза 3. Релизная раскладка статики

Единственная фаза с простоем. Превращает плоский `/srv/sites/<name>/` в `releases/` + `current`.

**Бэкап (обязательно, до всего):**

```sh
sudo tar czf "/root/sites-backup-$(date +%Y%m%d-%H%M%S).tar.gz" -C /srv sites
sudo cp -a /srv/caddy/Caddyfile "/root/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
```

**Команда:**

```sh
sudo /srv/deploy/migrate.sh sites --dry-run
sudo /srv/deploy/migrate.sh sites
```

**Ручной эквивалент для одного статического проекта:**

```sh
NAME=myapp
STAMP="legacy-$(date +%Y%m%d-%H%M%S)"
SITE="/srv/sites/$NAME"

# уже мигрирован — пропустить (идемпотентность)
if [ -L "$SITE/current" ]; then
    echo "$NAME уже мигрирован"
else
    mv "$SITE" "$SITE.migrating"
    install -d -o deploy -g deploy "$SITE/releases"
    mv "$SITE.migrating" "$SITE/releases/$STAMP"
    ln -sfn "releases/$STAMP" "$SITE/current"   # ОТНОСИТЕЛЬНЫЙ путь — важно для контейнера
    chown -h deploy:deploy "$SITE/current"

    # Обязательно: релиз должен попасть в журнал порядка. Ротация оставляет
    # текущий релиз и пять последних записей журнала, поэтому релиз, которого
    # в журнале нет, будет удалён при первом же деплое — и откатиться на
    # версию «до миграции» станет некуда.
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STAMP" \
        >> "/srv/state/$NAME/releases.tsv"
    chown deploy:deploy "/srv/state/$NAME/releases.tsv"
fi
```

Симлинк обязан быть относительным: Caddy видит файловую систему через bind-mount `/srv/sites:/srv/sites:ro`, и абсолютный симлинк разрешится внутри контейнера корректно только потому, что путь монтирования совпадает. Относительный симлинк не зависит от этого совпадения и переживёт смену пути монтирования.

**Проверка до перезапуска Caddy:**

```sh
for d in /srv/sites/*/; do
    name=$(basename "$d")
    if [ -L "$d/current" ]; then
        echo "OK   $name -> $(readlink "$d/current")"
        [ -f "$d/current/index.html" ] || echo "WARN $name: нет index.html в current"
    else
        echo "SKIP $name (не статика)"
    fi
done
```

---

## Фаза 4. Конфигурация Caddy

**Команда** (запускается из склонированного репозитория `sandbox-infra`, не из `/srv/deploy`):

```sh
sudo ./update-infra.sh --caddy-only --dry-run   # сначала посмотреть diff
sudo ./update-infra.sh --caddy-only
```

`update-infra.sh` сохраняет текущий `Caddyfile` в `/root/sandbox-backups/Caddyfile-<ts>`, извлекает из него уже вписанные домен и email, подставляет их в новый шаблон, показывает diff, и только после подтверждения заменяет файл. Дальше он прогоняет `caddy validate` на установленном файле и при провале возвращает бэкап. `.env` не трогается.

**Ручной эквивалент:**

```sh
sudo cp -a /srv/caddy/Caddyfile "/srv/caddy/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)"
sudo install -d -o deploy -g deploy /srv/caddy/spa.d
sudo touch /srv/caddy/spa.d/.keep
```

Затем в `/srv/caddy/Caddyfile` изменить корень раздачи и подключить SPA-правила:

```caddyfile
*.sandbox.<домен> {
    tls {
        dns timeweb {env.TIMEWEB_API_TOKEN}
    }

    import /srv/caddy/spa.d/*.caddy

    @app header_regexp app Host ^([a-z0-9]([a-z0-9-]*[a-z0-9])?)\.sandbox\.<домен>$
    handle @app {
        root * /srv/sites/{re.app.1}/current
        file_server
    }

    handle {
        respond "Unknown sandbox project" 404
    }
}
```

Готовый шаблон лежит в `caddy/Caddyfile` — бери его оттуда и подставь свой домен, а не переписывай руками.

`spa.d/*.caddy` подключается **до** общего `handle`: блоки `handle` взаимоисключающие и проверяются в порядке записи, поэтому SPA-проекты перехватываются своими правилами, а все остальные попадают в обычный `file_server` с честными 404. Файлы в `spa.d/` генерирует деплой-хук по `spa=true` из конфига проекта; на этапе миграции каталог пуст, и поведение всех существующих сайтов не меняется.

Регулярное выражение приведено в соответствие с правилом валидации имён (дефис не может быть первым или последним символом) — раньше оно принимало и `-foo-`.

Домен подставить фактический — тот, что уже стоит в текущем `Caddyfile`. Не полагаться на шаблон из репозитория: там `sandbox.example.com`.

**Монтирование:** `docker-compose.yml` Caddy уже монтирует `/srv/sites:ro` — этого достаточно, `releases/` и `current` лежат внутри. Дополнительно нужно смонтировать каталог с SPA-правилами:

```yaml
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./spa.d:/srv/caddy/spa.d:ro
      - /srv/sites:/srv/sites:ro
```

**Валидация до применения (обязательно):**

```sh
cd /srv/caddy
docker compose exec caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
```

Если контейнер уже перечитал файл и упал — валидировать одноразовым контейнером:

```sh
docker run --rm \
  -v /srv/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v /srv/caddy/spa.d:/srv/caddy/spa.d:ro \
  sandbox-caddy:latest caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
```

Валидация не проверяет DNS-токен и не выпускает сертификаты — она ловит только синтаксис и неизвестные директивы. Этого достаточно, чтобы не уронить прокси опечаткой.

**Применение:**

```sh
cd /srv/caddy && docker compose up -d
docker compose restart caddy
```

Сертификаты переиспользуются из volume `caddy_data` — wildcard не перевыпускается, повторного DNS-01 не будет.

---

## Фаза 5. Обновление скриптов деплоя

Выполняется последней, чтобы новый хук увидел уже готовые `/srv/state` и `/srv/sites/*/current`.

```sh
# на локальной машине
git push prod-infra main     # либо scp/rsync репозитория sandbox-infra на VPS

# на VPS
cd /path/to/sandbox-infra
sudo ./update-infra.sh --scripts-only
```

**Ручной эквивалент:**

```sh
sudo cp -a /srv/deploy "/root/deploy-backup-$(date +%Y%m%d-%H%M%S)"
sudo install -m 755 -o deploy -g deploy deploy/*.sh /srv/deploy/
```

Симлинки `post-receive` в bare-репозиториях указывают на `/srv/deploy/hook.sh` и обновляются автоматически — трогать их не нужно.

**Проверка симлинков (на случай, если где-то лежит копия вместо симлинка):**

```sh
for h in /srv/git/*.git/hooks/post-receive; do
    [ -L "$h" ] && echo "OK   $h -> $(readlink "$h")" || echo "COPY $h — заменить на симлинк"
done
```

**Локальный клиент.** `sandbox-deploy` живёт на рабочей машине, а не на VPS, и обновляется отдельно — иначе новые команды (`list`, `status`, `logs`, `redeploy`, `rollback`) будут недоступны, а старый клиент продолжит делать `git add -A` и автокоммит:

```sh
# на локальной машине, из репозитория sandbox-infra
install -m 755 client/sandbox-deploy ~/.local/bin/sandbox-deploy
sandbox-deploy list      # быстрая проверка, что клиент видит сервер
```

Старый клиент остаётся совместим с новым сервером для `push`/`stop`/`remove`, так что обновление можно сделать и после фазы 6.

---

## Фаза 6. Верификация

Пройти целиком, до объявления миграции успешной.

**Статика отдаётся:**

```sh
for d in /srv/sites/*/; do
    name=$(basename "$d")
    [ -L "$d/current" ] || continue
    code=$(curl -s -o /dev/null -w '%{http_code}' "https://$name.sandbox.<домен>/")
    echo "$name -> $code"
done
```

Ожидание: `200` для всех проектов, которые работали до миграции.

**Docker-проекты живы:**

```sh
docker ps --format '{{.Names}}\t{{.Status}}'
docker volume ls
```

Ожидание: тот же список контейнеров и volumes, что и до миграции. Ни один volume не должен пропасть или сменить имя.

**Деплой работает end-to-end.** На тестовом проекте (создать специально, не на живом):

```sh
sandbox-deploy migration-smoke-test
# локально: echo test > public/index.html; git add -A; git commit -m t; git push prod main
```

Проверить:

- [ ] Пуш в `main` деплоит; в `/srv/sites/migration-smoke-test/releases/` появился каталог с SHA коммита.
- [ ] `current` указывает на новый релиз.
- [ ] Пуш в ветку `feature/x` **не** деплоит.
- [ ] Заведомо ломающая сборка (`build_cmd=false`) не меняет `current`, сайт продолжает отдавать предыдущую версию.
- [ ] `sandbox-deploy rollback` возвращает предыдущий релиз без пересборки.
- [ ] `/srv/state/migration-smoke-test/deploys.tsv` содержит и успешную, и провалившуюся попытки, различимые по outcome.

**Существующий проект переживает передеплой.** Взять один реальный статический проект, сделать пустой коммит и запушить:

```sh
sandbox-deploy redeploy
```

Ожидание: сайт отдаёт то же содержимое, что и до миграции (`publish_dir=.` сохранил поведение), появился новый релиз, `current` переключился.

После успешной проверки удалить тестовый проект:

```sh
sudo /srv/deploy/remove-app.sh migration-smoke-test
```

---

## Откат

Откат возможен пофазно. Общее правило: откатывать в обратном порядке фаз.

**Откат фазы 5 (скрипты):**

```sh
sudo rm -rf /srv/deploy
sudo cp -a /root/deploy-backup-<ts> /srv/deploy
```

**Откат фазы 4 (Caddy):**

```sh
sudo cp -a /srv/caddy/Caddyfile.bak-<ts> /srv/caddy/Caddyfile
cd /srv/caddy && docker compose up -d && docker compose restart caddy
```

**Откат фазы 3 (раскладка статики):** вернуть плоскую структуру из релиза, на который смотрит `current`:

```sh
sudo /srv/deploy/migrate.sh sites --revert
```

Ручной эквивалент для одного проекта:

```sh
NAME=myapp
SITE="/srv/sites/$NAME"
TARGET="$SITE/$(readlink "$SITE/current")"
mv "$TARGET" "/srv/sites/$NAME.flat"
rm -rf "$SITE"
mv "/srv/sites/$NAME.flat" "$SITE"
```

Либо, если что-то пошло совсем не так, — из архива:

```sh
sudo rm -rf /srv/sites
sudo tar xzf /root/sites-backup-<ts>.tar.gz -C /srv
```

**Откат фазы 2:** `sudo rm -rf /srv/state`.

**Откат фазы 1 (имена):** `mv` обратно и `git remote set-url prod` обратно на локальной машине.

**Полный откат инфраструктуры к исходному коммиту:**

```sh
cd /path/to/sandbox-infra && git checkout f84cf38
sudo ./bootstrap.sh          # внимание: перезапишет Caddyfile шаблоном —
                             # сразу после этого восстановить Caddyfile.bak-<ts>
```

Docker-volumes ни одна фаза не удаляет, поэтому данные приложений откатом не затрагиваются. Если они всё-таки пострадали — единственный путь восстановления это снапшот диска из предусловий.

---

## Пост-миграция: добровольные шаги

Выполняются по одному проекту, в произвольное время, каждый — отдельно проверяемый.

**Переезд статического проекта на `public/`.** Убирает публикацию корня репозитория и вместе с ней — риск отдать наружу `.env`, `.git` и прочее:

```sh
# локально, в репозитории проекта
mkdir -p public
git mv index.html style.css assets public/      # перечислить фактические файлы
git commit -m "chore: move static files under public/"

# на VPS
sudo sed -i 's|^publish_dir=.*|publish_dir=public|' /srv/state/<name>/config

# локально
git push prod main
```

Проверить сайт. Если сломалось — вернуть `publish_dir=.` на сервере и откатить коммит; предыдущий релиз всё это время остаётся доступен через `sandbox-deploy rollback`.

**Включение SPA-режима:**

```sh
sudo sed -i 's|^spa=.*|spa=true|' /srv/state/<name>/config
```

Затем передеплой (хук сгенерирует `/srv/caddy/spa.d/<name>.caddy` и перезагрузит Caddy). Проверить: прямой заход на `/tools/regex` отдаёт `200` и приложение, а запрос несуществующего `/assets/nope.js` отдаёт `404`, а не HTML.

**`dockerfile-only` проекты.** Из фазы 0. Для каждого — либо добавить `docker-compose.yml` с лейблами Caddy, либо явно перевести в другой тип. До этого проект не деплоится и хук выдаёт внятную ошибку.

**Чистка старых релизов.** Миграция создала по одному релизу `legacy-<ts>` на проект. Ротация (хранить 5 последних, никогда не удалять текущий) начнёт работать сама со следующих деплоев; `legacy-<ts>` вытеснится естественным образом.

---

## Что проверено и что нет

**Проверено локально, автоматическими тестами** (`bash tests/run.sh`, 367 проверок, ShellCheck чист):

- Валидация имён и отказ удалять что-либо за пределами разрешённых корней, включая исходный сценарий `remove-app.sh '../../OUTSIDE' --force`.
- Фильтрация refs на настоящих git-пушах: пуш в другую ветку не деплоит, удаление ветки не деплоит, несколько refs в одном пуше, разворачивается именно переданный коммит.
- Блокировка: операция отклоняется, пока замок проекта занят.
- Упавшая сборка не переключает `current`, сайт продолжает отдавать предыдущий релиз, а хук и клиент сообщают о провале ненулевым кодом.
- Чистое дерево сборки: файл, удалённый из коммита, исчезает из раздачи.
- Отказ публиковать при симлинке за пределы каталога сборки; исключение `.env`, `.git` и ключей из публикации.
- Ротация релизов с защитой текущего и откат без пересборки.
- SPA: на **настоящем Caddy в контейнере** — вложенный маршрут отдаёт `index.html`, существующий ассет отдаёт себя, отсутствующий `.js`/`.css`/шрифт отдаёт 404, обычная статика продолжает возвращать 404 на неизвестный путь. Боевой шаблон `caddy/Caddyfile` проходит `caddy validate` вместе со сгенерированным сниппетом.
- `update-infra.sh`: домен и email переживают обновление, `.env` не трогается, бэкапы создаются, нераспознанный конфиг не перезаписывается.
- `migrate.sh`: `audit` ничего не меняет, `state` и `sites` идемпотентны, `--revert` возвращает плоскую раскладку, мигрированный релиз переживает ротацию, посторонние каталоги не затрагиваются.

**Не проверялось нигде, кроме как на VPS — проверять при миграции:**

- Выпуск и переиспользование wildcard-сертификата, DNS-01 через Timeweb.
- Разрешение относительного симлинка `current` внутри контейнера Caddy (снаружи проверено, внутри bind-mount — нет).
- Перезапуск `caddy-docker-proxy` с живым трафиком (ожидается короткий перерыв).
- `caddy validate` с боевым образом `sandbox-caddy:latest` — локально проверялось на `caddy:latest` с заменой `tls` на `internal`, потому что плагин timeweb в официальном образе отсутствует.
- Сохранность docker volumes и bind-mount данных после фаз 1–5.
- `docker compose` с фиксированным `COMPOSE_PROJECT_NAME` на уже существующих контейнерах.
- Реальная работа `health_url` для Docker-проектов.
- Поведение `npm ci` / сборки на серверном Node.

**Сознательно вне скоупа:** автоматический откат Docker-приложений и миграций БД, перенос существующих проектов на `public/` (добровольный шаг выше), любые изменения DNS.
