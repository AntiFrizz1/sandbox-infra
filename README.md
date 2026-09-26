**Русский** | [English](README.en.md)

# Sandbox-инфраструктура для VPS

Git-push деплой для статики, SPA и Docker-приложений через один общий
post-receive хук и Caddy с автоматическим TLS (DNS-01, Timeweb). Рассчитана
на одного владельца: деплоит только он, а посетитель взломанного тестового
проекта не должен добраться до сервера.

## Документация

- [Установка на VPS](docs/ru/install.md) — подготовка образов, bootstrap,
  DNS, клиент, обновление и обслуживание.
- [Деплой статического сайта](docs/ru/deploy-static.md)
- [Деплой Node-проекта со сборкой (Vite, React, SPA)](docs/ru/deploy-node.md)
- [Деплой Docker-проекта (backend, база, бот)](docs/ru/deploy-docker.md)
- [Перевод работающего VPS](docs/MIGRATION.md) и
  [подробный план со старой раскладки](docs/MIGRATION-LEGACY.md)
- [Runbook применения и отката](docs/SECURITY-RUNBOOK.md). Аудит
  безопасности, план исправлений и их статус не публикуются, пока действующий
  VPS не обновлён.

## Security remediation

Текущая ветка меняет совместимость: Node-проекты собираются только в
изолированном worker, а Docker-проекты запускаются только по root-политике и
после проверки compose-файла — без политики проект не деплоится. Публичный
Caddy отделён от controller с Docker socket; при обновлении нужны перенос
Caddyfile в `config/` и сохранение томов с сертификатами. Это локально
проверенный кандидат, на действующий VPS он ещё не применён. Не используй
прежнюю процедуру массового обновления без
[runbook](docs/SECURITY-RUNBOOK.md).

## Быстрый старт

На своей машине: собрать образы и экспортировать архивы с контрольными
суммами.

```bash
docker build -t sandbox-caddy:candidate caddy/
docker build -t sandbox-worker:candidate worker/
scripts/scan-image.sh sandbox-caddy:candidate caddy      # рекомендуется
scripts/scan-image.sh sandbox-worker:candidate worker
scripts/export-image.sh sandbox-caddy:candidate caddy.tar --artifact caddy
scripts/export-image.sh sandbox-worker:candidate worker.tar --artifact worker
```

На VPS (Ubuntu 22.04/24.04, от root):

```bash
git clone https://github.com/AntiFrizz1/sandbox-infra.git /root/sandbox-infra && cd /root/sandbox-infra
SANDBOX_CADDY_ARCHIVE=/root/caddy.tar SANDBOX_CADDY_ARCHIVE_SHA256=<sha256> \
SANDBOX_WORKER_ARCHIVE=/root/worker.tar SANDBOX_WORKER_ARCHIVE_SHA256=<sha256> ./bootstrap.sh
```

Затем домен и email в Caddyfile, токен Timeweb, DNS-записи и SSH-ключи —
по шагам в [docs/ru/install.md](docs/ru/install.md). Проект:

```bash
sandbox-deploy init myapp && sandbox-deploy push
```

## Типы проектов

| Тип | Когда | Что нужно на сервере | Руководство |
|---|---|---|---|
| `static` | готовые HTML/CSS/JS | ничего | [deploy-static.md](docs/ru/deploy-static.md) |
| `node` | фронтенд со сборкой | ничего (общая политика worker) | [deploy-node.md](docs/ru/deploy-node.md) |
| `docker` | backend, база, бот, SSR | ничего (общая политика compose) | [deploy-docker.md](docs/ru/deploy-docker.md) |

Тип и каталог публикации задаются `.sandbox.conf` в корне репозитория
(примеры — в `examples/`), иначе определяются по файлам: compose-файл →
`docker`, `package.json` → `node`, иначе `static`.

```
type=static|node|docker   # если не задан — определяется автоматически
publish_dir=public        # что публиковать; по умолчанию public/ (static) и dist/ (node)
build_cmd=npm run build   # только для node
spa=false                 # true — fallback на index.html для маршрутов SPA
health_url=               # docker: https://<app>.<домен>/… (проверка через Caddy)
```

Проект доступен на `https://<app>.sandbox.<домен>`. Деплоит только ветка
`main`.

## Структура репозитория

```
bootstrap.sh          — разовая установка на чистый VPS
update-infra.sh       — обновление уже установленной инфраструктуры
examples/             — .sandbox.conf для статики, Vite, Docker и старой раскладки;
                        root-политики worker-policy.conf и compose-policy.conf
tests/                — тесты (bash tests/run.sh) и обязательные integration-скрипты
scripts/check-release.py — release gate по манифесту образов и сканам
scripts/scan-image.sh    — скан Trivy и SBOM Syft образа в манифест релиза
scripts/export-image.sh  — архив проверенного образа для переноса на VPS
docs/
  ru/, en/               — руководства по установке и деплою
  MIGRATION.md           — перевод уже развёрнутого VPS на новую раскладку
  MIGRATION-LEGACY.md    — подробный пофазный план со старой раскладки
  SECURITY-RUNBOOK.md    — применение изменений безопасности и откат
caddy/
  Dockerfile           — сборка Caddy через xcaddy (docker-proxy + timeweb), по digest
  docker-compose.yml   — публичный server и controller с Docker socket
  Caddyfile             — конфиг Caddy (домен и email — placeholder'ы)
  .env.example          — шаблон для TIMEWEB_API_TOKEN
worker/
  Dockerfile, run.sh     — одноразовый контейнер сборки Node (fetch / build)
deploy/
  hook.sh                — общий post-receive хук, определяет тип проекта и деплоит
  lib/common.sh          — валидация имён, защита путей, закрытые файлы, блокировки
  lib/project.sh         — тип проекта, .sandbox.conf, каталог публикации
  lib/release.sh         — атомарная публикация релизов и откат
  lib/caddy.sh           — пер-проектные SPA-правила и перезагрузка Caddy
  lib/runner.sh          — root-политики и двухфазный worker
  lib/compose.sh         — запуск Docker-проектов по политике profile=compose
  lib/migration.sh       — безопасная миграция раздачи с бэкапом и карантином
  lint-compose.py        — проверка compose-модели по белому списку
  bounded-log.py         — лог деплоя с ограничением размера
  new-app.sh             — создание нового bare-репозитория на VPS
  redeploy-app.sh        — пересборка текущей main без нового коммита
  stop-app.sh            — временная остановка проекта
  rollback-app.sh        — откат на предыдущий релиз без пересборки
  status-app.sh          — состояние проекта, проверка исхода деплоя
  list-apps.sh           — список всех проектов с их состоянием
  logs-app.sh            — логи деплоев
  cleanup-app.sh         — очистка завершённых логов проекта
  repair-permissions.sh  — исправление прав закрытого состояния
  remove-app.sh          — полное удаление проекта
  migrate.sh             — перевод старой раскладки на новую
  load-image.sh          — загрузка образа из архива с проверкой SHA-256
  maintenance.sh         — ежедневная очистка и проверка места (по таймеру)
  firewall.sh            — запрет доступа из контейнеров к хосту и частным сетям
  userns.sh              — включение userns-remap и перенос томов
  harden-host.sh         — автообновления и SSH только по ключу
  systemd/               — sandbox-maintenance.{service,timer}, sandbox-firewall.service
client/
  sandbox-deploy           — локальный интерактивный клиент (см. ниже)
```

## Обновление инфраструктуры

`bootstrap.sh` — только для первой установки. Для обновления уже работающего
VPS есть отдельный скрипт, который **не затирает настройки**:

```bash
cd /path/to/sandbox-infra && git pull
sudo ./update-infra.sh --dry-run    # показать, что изменится
sudo ./update-infra.sh
```

Он переносит домен и email из действующего `Caddyfile` в новый шаблон,
показывает diff, делает бэкап в `/root/sandbox-backups/`, прогоняет
`caddy validate` и откатывается, если проверка не прошла. Скрипты в
`/srv/deploy` ставятся от root, systemd-юниты обслуживания и firewall
обновляются и включаются. `.env`, состояние проектов, релизы и
bare-репозитории не затрагиваются. Новый `docker-compose.yml` Caddy ставится
только после переноса Caddyfile в `/srv/caddy/config/` по runbook.
userns-remap и закалку хоста `update-infra` сам не включает: на работающем
VPS это делается отдельно (`userns.sh`, `harden-host.sh`, runbook).
Флаги `--scripts-only` и `--caddy-only` обновляют части по отдельности.
Новые образы — через `load-image.sh`, см.
[установку](docs/ru/install.md#обновление).

## Релизы и откат

Статика публикуется не «поверх» предыдущей версии, а в отдельный каталог,
связанный с коммитом:

```
/srv/sites/<app>/releases/<sha>/     сборка конкретного коммита
/srv/sites/<app>/current -> releases/<sha>    относительный симлинк
```

Ссылка `current` переключается атомарно (`rename(2)`) и только после
успешной сборки и проверки её вывода. Поэтому упавшая сборка не ломает
работающий сайт: он продолжает отдавать предыдущий релиз. Хранятся пять
последних успешных релизов, текущий не удаляется никогда.

```bash
/srv/deploy/rollback-app.sh myapp           # на предыдущий релиз
/srv/deploy/rollback-app.sh myapp --list    # что сохранено
/srv/deploy/rollback-app.sh myapp a1b2c3d   # на конкретный релиз
```

Откат только переключает ссылку — пересборки не происходит.
Повторная сборка того же коммита получает ID `<sha>.<suffix>`; предыдущий
каталог остаётся неизменным. `rollback --list` показывает полные ID сборок.

Блокировки находятся в `/srv/state/.locks/<app>.lock`, общая блокировка
конфигурации Caddy — в `/srv/state/.locks/.caddy.lock`. Эти файлы сохраняются
при удалении проекта, чтобы ожидающие процессы продолжали использовать
одну блокировку. При обновлении старой версии нужно дождаться завершения
всех операций: старый и новый пути блокировки нельзя использовать одновременно.

Состояние проекта на сервере лежит в `/srv/state/<app>/`:

```
config                 серверный конфиг (если нет .sandbox.conf в репозитории)
env                    runtime-секреты Docker-проекта: копируются в его .env и
                       служат единственным источником интерполяции compose
build-env              секреты, которые получает фаза build в worker (Node)
deploys.tsv            история: время, ветка, sha, исход, длительность
releases.tsv           порядок успешных релизов
docker-active-sha      коммит, запущенный в Docker-проекте
compose.override.json  серверные лимиты и ограничения для compose
logs/<sha>.log         лог деплоя конкретного коммита (до 1 MiB)
```

Все эти файлы закрыты (каталоги 0700, файлы 0600).

## Остановка и удаление проекта

```bash
/srv/deploy/stop-app.sh myapp     # временно остановить, данные сохраняются
/srv/deploy/remove-app.sh myapp   # удалить полностью и необратимо
```

`stop-app.sh` останавливает Docker-контейнеры (`docker compose -p <app> down`,
по имени проекта, не читая compose-файл) либо снимает ссылку `current` —
сами релизы при этом сохраняются, поэтому проект можно вернуть откатом, не
дожидаясь пересборки. Bare-репозиторий не трогается. Для запуска без нового
коммита используй `sandbox-deploy redeploy myapp`: повторный push
неизменённой ветки не запускает хук.

`remove-app.sh` сносит всё: bare-репозиторий, рабочий чекаут, статику и (для
Docker-проектов) контейнеры/volumes/локально собранные образы. Спрашивает
подтверждение, если не передан флаг `--force`/`-y`.

## Локальный клиент `client/sandbox-deploy`

Интерактивный bash-скрипт для машины разработчика — избавляет от ручного
логина по SSH при создании нового проекта.

Что делает:
- Для существующего проекта берёт имя из remote `prod`, а не из имени папки:
  папку могли переименовать или склонировать под другим именем.
- Работает внутри git worktree, где `.git` — файл, а не каталог.
- **Не трогает рабочее дерево.** Пушит только то, что уже закоммичено, и
  предупреждает о незакоммиченных изменениях. Закоммитить явно:
  `--commit-all "сообщение"`.
- Не переименовывает текущую ветку. Пуш отправляет `HEAD` в
  `refs/heads/main`, поэтому локальная ветка может называться как угодно.
- **Проверяет, что деплой действительно прошёл.** Провалившийся
  `post-receive` не отменяет уже принятый пуш, поэтому нулевой код возврата
  `git push` ничего не доказывает. Клиент спрашивает у сервера исход деплоя
  именно этого коммита и завершается с ошибкой, если тот провалился.
- Для подтверждения операций в скриптах нужен явный `-y` / `--yes`.
  Отсутствие терминала само по себе не подтверждает удаление или другие операции.

Настройка (без хардкода хоста в самом скрипте — его можно спокойно класть
в публичный репозиторий со своими скриптами):

```bash
mkdir -p ~/.config/sandbox-deploy
echo 'SANDBOX_HOST=deploy@sandbox.example.com' > ~/.config/sandbox-deploy/config
```

Использование:

```bash
sandbox-deploy init [myapp]        # создать проект на VPS и настроить remote
sandbox-deploy push                # запушить и дождаться результата деплоя
sandbox-deploy push --commit-all "сообщение"   # закоммитить всё и запушить
sandbox-deploy status [myapp]      # активный релиз и последний деплой
sandbox-deploy list                # все проекты на VPS
sandbox-deploy logs [myapp] [sha|--list]
sandbox-deploy redeploy [myapp]    # пересобрать серверную main, сохранив локальный индекс
sandbox-deploy rollback [myapp] [sha|--list]
sandbox-deploy stop [myapp]        # временно остановить
sandbox-deploy remove [myapp]      # полностью и необратимо удалить
```

Имя проекта необязательно — оно берётся из remote `prod`. Флаг `-y`/`--yes`
отключает все вопросы.

`status` отдельно показывает активный релиз и последнюю попытку деплоя.
Проверка `--check` сверяет SHA с активной версией: исторический успех после
остановки или отката возвращает `inactive`. Это разные вещи: провалившийся
статический деплой не меняет того, что отдаётся, и
`status` прямо скажет, что сайт работает на предыдущем коммите.

## Раздача и SPA

`spa=true` включает fallback на `index.html`, но только для того, что похоже
на маршрут приложения. Существующие файлы отдаются как есть, а отсутствующий
`.js`, `.css`, шрифт или картинка честно возвращают 404 — иначе браузер
получил бы HTML вместо скрипта и упал с невнятной ошибкой разбора.

Правила генерируются деплой-хуком в `/srv/caddy/spa.d/<app>.caddy` и
импортируются внутрь wildcard-блока Caddyfile. Отдельный site-блок на проект
не используется намеренно: он заставил бы Caddy выпускать по сертификату на
каждый поддомен вместо одного wildcard.

Перед применением конфигурация проверяется `caddy validate`.
Затем перезапускается controller: он собирает конфигурацию вместе
с маршрутами Docker labels и передаёт её публичному server по отдельной
управляющей сети. Общий lock сериализует изменения Caddy. В старой раскладке
контейнер пересоздаётся, чтобы обновился bind-mount inode; это даёт перерыв.
Обычный `caddy reload` базового Caddyfile использовать нельзя: в нём нет
сгенерированных Docker-маршрутов. Если проверка не прошла, правила
откатываются и Caddy не перезагружается. Если Caddy сейчас не запущен,
правила остаются на диске и подхватятся при следующем старте.

Публикуется **только** `publish_dir`, а не весь репозиторий. Это защищает от
случайной отдачи наружу исходников и серверных файлов. Даже внутри него не
публикуются dot-файлы (кроме `.well-known`), `.env*`, `*.env`, ключи
(`*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`), `.sandbox.conf` и корневой
`node_modules`. Caddy независимо от этого отвечает 403 на dot-пути, `.env`
и ключи, в том числе вложенные и URL-encoded. Симлинки, уводящие за пределы
публикуемого каталога, отвергаются, и деплой падает с ошибкой.

## Защита хоста от взломанного проекта

Тестовый проект может оказаться дырявым: посетитель получит выполнение кода
в его контейнере. Дальше его держат:

- **firewall** (`deploy/firewall.sh`, юнит `sandbox-firewall.service`):
  из контейнеров закрыт доступ к самому хосту (SSH и любые его сервисы),
  к частным сетям (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`) и к
  метаданным облака (`169.254/16`). Интернет открыт, связь Caddy → приложение
  не затронута. Приложение, которому нужна база на хосте или в частной сети
  провайдера, так работать не будет — держи базу в compose проекта;
- **userns-remap** (`deploy/userns.sh`, bootstrap включает его на чистом
  Docker): root внутри контейнера проекта — непривилегированный UID хоста,
  так что даже выход из контейнера через уязвимость ядра не даёт root на VPS.
  Каталог, в который контейнер пишет через bind-mount, должен принадлежать
  сдвинутому UID; удобнее хранить такие данные в именованных томах. Перевод
  работающего VPS — в `docs/SECURITY-RUNBOOK.md`;
- урезанные capabilities и `no-new-privileges` из серверного override
  (см. [deploy-docker.md](docs/ru/deploy-docker.md));
- **закалка хоста** (`deploy/harden-host.sh`, запускает bootstrap):
  `unattended-upgrades` ставит обновления безопасности и ночью, в 04:30,
  перезагружает сервер, если обновилось ядро (`SANDBOX_AUTO_REBOOT=false`
  отключает перезагрузку); SSH — только по ключу, root тоже. Пароли
  отключаются, только если у root уже есть ключ в `authorized_keys`, иначе
  шаг пропускается с предупреждением — чтобы не запереть вход. На уже
  установленном VPS запусти `sudo /srv/deploy/harden-host.sh` вручную.

## Пока не реализовано (отложено)

- Не-HTTP TCP-протоколы (нужен `caddy-l4`; публикация портов проектами
  запрещена compose-политикой).
- Процессы без Docker через systemd unit-файлы.
- Изоляция проектов друг от друга внутри `sandbox_net`.

## Тесты

```bash
bash tests/run.sh
```

Тестам нужны bash, git, rsync, coreutils, flock, python3 с PyYAML и
docker compose. Они работают во временных каталогах — реальный `/srv` не
трогают. ShellCheck запускается автоматически, а если его нет в системе —
через `koalaman/shellcheck` в docker.

Docker-тесты поднимают настоящий Caddy и проверяют HTTP-ответы, права после
миграции от root, compose-политику на реальном контейнере. Firewall, закалка
хоста и userns-remap проверяются в одноразовых контейнерах (в том числе
privileged и docker-in-docker): iptables, sshd и настройки Docker этой машины
не меняются, её кеш сборки не чистится. Без docker эти проверки
пропускаются. При первом запуске скачиваются образы Debian, Caddy и
`docker:28-dind`.

Для выпуска обязательны также `tests/security-integration.sh`,
`tests/proxy-isolation.sh`, `tests/worker-isolation.sh`; отсутствие
Docker/образов считается отказом этих проверок.

## Проверки и ограничения ресурсов

Лог одного деплоя ограничен 1 MiB. Деплой не начинается, если свободно
меньше `SANDBOX_MIN_FREE_MB` (1024). Дерево сборки worker ограничено
`output_mb` из политики: dispatcher опрашивает размер и свободное место и
убивает контейнер при превышении. Это опрос, а не квота файловой системы:
между проверками (5 с) сборка успевает записать лишнее.

`sandbox-maintenance.timer` (ставят bootstrap и update-infra) раз в сутки
запускает `maintenance.sh`: завершённые логи (20 шт./20 MiB, 200 записей
истории), остатки прерванных деплоев — только если проект не занят,
`git gc --auto`, кеш сборки Docker и висячие образы старше недели, бэкапы
миграции сверх трёх последних и старше 30 дней. Опубликованные релизы,
volumes и данные приложений не трогаются. При свободном месте меньше
`SANDBOX_ALERT_FREE_MB` (2048) юнит завершается с кодом 2 — он виден в
`systemctl --failed` и журнале. `maintenance.sh --dry-run` показывает план.
