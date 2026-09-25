# Применение security remediation на VPS

Этот документ — runbook, не свидетельство выполненной миграции VPS.
В текущей сессии не выполнялись деплой, push, ротация реальных credentials
или операции с данными VPS. Исходный аудит и исторические PoC не изменены.

## Условия выпуска

Не применять дерево без review и отдельного разрешения оператора. Новый hook
намеренно отклоняет host Compose; Node требует root-owned worker policy.
Сначала инвентаризировать такие проекты и выбрать окно/профиль миграции.
Не заменять массово работающий hook до этой инвентаризации.

Запуск обязательных локальных проверок:

```bash
bash tests/run.sh
bash tests/security-integration.sh
bash tests/proxy-isolation.sh
bash tests/worker-isolation.sh
```

`tests/run.sh` допускает исторические SKIP при отсутствии Docker; это не
приёмка релиза. Три отдельных integration-скрипта обязаны пройти, а полный
вывод не должен содержать SKIP/FAIL. Артефакты в `docs/security-remediation/`
относятся только к указанным в них image ID/digest. Сверить их с фактическим
образом. Не пересобирать образ на VPS. Локальный image ID не означает,
что образ опубликован в registry или доступен другому daemon.

До выпуска сохранить исходный commit (после отдельного коммита оператором),
Git diff/чистоту дерева, Dockerfile, платформу, версии инструментов, SBOM,
scan, время обновления vulnerability DB и digest итогового образа. Scan с
найденными уязвимостями — не одобрение выпуска. Каждое исключение требует
конкретного CVE, объяснения достижимости, владельца и срока; автоматического
исключения в этом изменении нет. При недоступной/устаревшей DB выпуск заблокирован.

Pins пересматривать ежемесячно и сразу при security advisory. Для обновления
собрать новый кандидат, проверить версии через registry/Go module checksum DB,
повторить tests/SBOM/scan, одобрить digest и сохранить предыдущий одобренный
артефакт. Обновление apt-пакетов ОС не блокируется package hold. Bootstrap
использует подписанные репозитории дистрибутива, без curl|sh; пакет
`docker-compose-v2` рассчитан на Ubuntu, для другого дистрибутива предварительно
установить Docker и Compose из его подписанного репозитория.

## Инвентаризация без вывода секретов

Оператор фиксирует список проектов, типы, домены, active release, все ссылки,
владельцев/режимы state, logs, env, hooks и config; размер repos, releases,
cache, volumes и резервов диска. Снять `docker inspect` mounts/networks/image ID
в закрытый файл: inspect может содержать env. Не публиковать этот файл в отчёте.
Проверить отсутствие TCP Docker API, выделить свободную control-подсеть,
проверить firewall и доступ к admin endpoints из других Docker-сетей.

Подготовить закрытый `/var/backups/sandbox`, root:root 0700, вне `/srv/sites`
и **всех** mounts Caddy. Сохранить config, .env, manifests, журналы и список
image digest. Остановить новые deploy через SSH/post-receive admission и
дождаться всех текущих процессов, включая старые hooks без новых locks.
Копирование/установка скриптов не является атомарным обновлением всего VPS.

## Первый набор: пути, публикация, права

1. Сначала установить HTTP guard из нового Caddyfile и регенерировать старые
   SPA snippets с импортом guard. Выполнить `caddy validate` и HTTP-проверки.
   Сохранить прежнюю конфигурацию закрыто. При bind mount отдельного файла
   rename может не обновить видимый inode: до миграции mount требуется
   пересоздание контейнера с сохранением named certificate volumes.
2. После остановки deploy установить reviewed scripts от root:root,
   каталоги 0755, scripts 0755, libraries/Python helper 0644. У пользователя
   сборки не должно быть права записи в dispatcher или server policy.
3. Выполнить `migrate.sh state --dry-run` и `migrate.sh sites --dry-run`.
   Разобрать каждый отказ: чужой symlink, `site.flat`, `site.migrating`,
   неоднозначный current. Не удалять найденные остатки автоматически.
4. Выполнить `migrate.sh state`, затем `migrate.sh sites`. Последняя команда
   проверяет существующие releases, сохраняет tar без разыменования ссылок,
   проверяет backup через tar compare, создаёт безопасный новый release,
   переносит unsafe-версии в закрытый quarantine. Непригодный активный release
   снимается с раздачи. При ошибке уже завершённые проекты не откатываются.
5. `repair-permissions.sh --dry-run`, затем `repair-permissions.sh`. Это не
   рекурсивный chmod application data. Caddy .env получает `root:deploy 0640`:
   Compose, который deploy-хук вызывает для validate/reload, обязан читать
   `.env`, а при `0600 root` хук молча считает Caddy остановленным и не
   применяет SPA-правила. Deploy состоит в группе docker и так видит токен
   через `docker inspect`; режим закрывает его от остальных UID. Проверить
   state/logs 0700, env/logs 0600, публичные dirs/files 0755/0644, включая
   `/srv/sites/<name>` и `releases/` — proxy без `CAP_DAC_OVERRIDE` не пройдёт
   каталог 0700. Симлинки требуют ручного разбора и не исправляются через разыменование.
6. Восстановить tar в **отдельный закрытый каталог**, проверить содержимое и
   права; никогда не восстанавливать unsafe backup в публичную раздачу.
   Повторить dry-run и обычную миграцию: safe current должен остаться прежним.
7. HTTP GET/HEAD `.env`, `.env.production`, `.npmrc`, ключи, вложенные и encoded
   варианты должны возвращать 403, включая SPA. Проверить `.well-known`/ACME,
   `/`, статические ассеты, SPA route, stop/redeploy/rollback и чтение секретов
   от второго UID. Имена файлов не обнаруживают произвольно названный секрет.
8. Если подтверждена прежняя публикация реального секрета — отдельно отозвать
   credential и выпустить новый; этот runbook не выполняет ротацию сам.

## Второй набор: прокси, worker, Docker-проекты

1. Подготовить утверждённые Caddy/worker digest и SBOM/scan. В private
   `/srv/caddy/.env` записать `SANDBOX_CADDY_IMAGE=<registry>@sha256:<digest>`.
   Значение должно быть доступно Compose на последующих рестартах.
2. Под общим Caddy lock перенести Caddyfile в `/srv/caddy/config/Caddyfile`,
   config dir оставить root-owned, 0755; snippets — `/srv/caddy/spa.d`.
   Новый Compose монтирует каталог config read-only, **без .env**.
   Сохранить имя Compose-проекта, чтобы `caddy_data`/`caddy_config` использовали
   прежние volumes. Ни в одной команде миграции не применять `down -v`.
3. Проверить `docker compose config --quiet`, отсутствие конфликта
   `SANDBOX_CONTROL_SUBNET`, затем применить утверждённый split Compose.
   Public server не имеет Docker socket. Controller имеет socket, не имеет
   публичных портов и не подключён к ingress. Его компрометация по-прежнему
   привилегированна. Проверить отсутствующий сетевой Docker API и доступ к
   controller/admin из ingress. Контрольная сеть — доверенная; её нельзя
   предоставлять проектам. DNS token получает server, которому нужен challenge;
   RCE этого процесса всё ещё раскрывает token. Scope Timeweb требует отдельной
   проверки аккаунта/зоны. DNS smoke проводить на ACME staging/test domain.
4. Worker policy: `/etc/sandbox/projects/<name>.conf`, root:root 0644; все
   родительские каталоги root-owned и без group/world-write. Образ заранее
   загрузить по утверждённому digest. Зависимости скачивает отдельный
   контейнер fetch в сети `fetch_network` (bootstrap создаёт `sandbox_build`
   с меткой `sandbox.role=build`; сеть без метки отвергается) командой
   `npm ci --ignore-scripts` — код проекта и зависимостей там не выполняется.
   Контейнер build всегда без сети. Остаточный риск fetch: npm по lockfile
   делает GET на произвольные URL (в том числе внутренние адреса VPS);
   ответ проверяется integrity и в раздачу не попадает. Если это неприемлемо,
   `fetch_network=none` и заранее подготовленные зависимости.
   Профиль из репозитория не даёт права изменить execution policy.
5. Runtime env не передаётся Node. Только явно подготовленный `state/<name>/build-env`
   доступен worker; это отдельный набор разрешённых build secrets. Весь этот
   файл доступен коду worker, включая lifecycle-процессы; он не защищён от них.
   Секреты не включать в image layers и не публиковать с output.
6. Docker-проекты запускаются на host daemon только с root-политикой
   `profile=compose` и после `lint-compose.py` (нужен `python3-yaml`).
   Перед выдачей политики прогнать проверку на текущем compose-файле
   проекта: всё, что линтер отвергает (опубликованные порты, bind вне
   каталога проекта, чужие сети и т. п.), переделать заранее. Имя
   compose-проекта остаётся `<name>`, поэтому существующие volumes
   `<name>_*` сохраняются. Это не rootless-граница: код контейнеров и
   Dockerfile по-прежнему исполняется root daemon'ом.
7. Проверить timeout, реальные CPU/RAM/PID limits, отсутствие дочерних
   контейнеров после ошибки, повторный deploy и сохранение current. Candidate
   defaults: 300 s, 512 MiB, 128 PID, 1 CPU; уточнить по измерениям VPS.
   Дерево сборки ограничено `output_mb` (опрос размера и свободного места,
   kill контейнера); деплой не стартует ниже `SANDBOX_MIN_FREE_MB`. Это не
   квота файловой системы: между опросами возможен перерасход.
8. `maintenance.sh --dry-run`, затем проверить, что `sandbox-maintenance.timer`
   включён (`systemctl list-timers`). Retention: логи 20 шт./20 MiB, история
   200 записей, остатки прерванных деплоев только у незанятых проектов,
   `git gc --auto`, Docker build cache и висячие образы старше недели,
   migration-бэкапы сверх трёх последних и старше 30 дней. Active/last и
   неизвестные артефакты сохраняются. Код выхода 2 — мало места; подключить
   к нему уведомление (например, `OnFailure=` юнита) по своему вкусу.
   `docker system prune --volumes` не использовать.

## Откат

Сначала остановить admission, дождаться locks. Вернуть только предыдущий
**проверенный** image digest и совместимую конфигурацию, сохраняя HTTP guard,
закрытые permissions, safe releases, root-owned policy и скрипты. Проверить
reload/HTTP, Docker-route и сертификаты. Не возвращать socket публичному
server и host-execution worker ради восстановления доступности. Если старый
артефакт требует этих прав, остановить затронутый проект и исправить вперёд.

`migrate.sh sites --revert` возвращает только проверенный безопасный current
в плоскую раскладку; секреты из backup не возвращаются. Перед этой командой
оператор сохраняет snapshot всех требуемых safe releases/истории: остальные
release-каталоги удаляются как часть возврата плоской раскладки. Конфигурацию
раздачи менять согласованно и сохранять deny-правила. Backup с небезопасным
содержимым восстанавливать исключительно вне mounts Caddy.
