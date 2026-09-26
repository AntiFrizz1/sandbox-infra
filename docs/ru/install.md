**Русский** | [English](../en/install.md)

# Установка на VPS

Руководство по установке sandbox-infra на чистый VPS: от подготовки образов
на своей машине до первого проекта. Перевод уже работающего сервера на
новую версию описан отдельно — в [SECURITY-RUNBOOK.md](../SECURITY-RUNBOOK.md)
и [MIGRATION.md](../MIGRATION.md).

## Как это устроено

```
 твоя машина                                 VPS
 ───────────                                 ───
 git push prod main ──ssh──▶ /srv/git/<app>.git
                                  │ post-receive → /srv/deploy/hook.sh
                                  ▼
                 static ─────▶ /srv/sites/<app>/releases/<sha>, current → …
                 node   ─────▶ worker (fetch с сетью → build без сети) → releases
                 docker ─────▶ docker compose -p <app> (по root-политике)
                                  │
 браузер ──https──▶ Caddy (server) ◀── controller (читает Docker labels)
                    https://<app>.sandbox.<домен>
```

- Статика и собранные SPA раздаются Caddy из `/srv/sites/<app>/current`
  под одним wildcard-сертификатом `*.sandbox.<домен>` (DNS-01 через Timeweb).
- Docker-проекты публикуются через лейблы `caddy:` в своём compose-файле;
  для них Caddy получает отдельный сертификат через HTTP-01.
- Деплоит только владелец сервера. Защита рассчитана на то, чтобы посетитель
  взломанного тестового проекта не добрался до сервера (см.
  «Защита хоста» в [README](../../README.md)).

## Что понадобится

**VPS**
- Ubuntu 22.04 или 24.04 (bootstrap ставит `docker.io` и
  `docker-compose-v2` из репозиториев Ubuntu; на Debian Docker и Compose
  нужно заранее поставить из подписанного репозитория Docker).
- Доступ по SSH как root, лучше сразу по ключу.
- Память: Caddy, worker сборки (по умолчанию до 512 МБ) и твои
  Docker-проекты. Для пары тестовых проектов разумно от 2 ГБ.

**Домен и DNS в Timeweb**
- Домен, DNS-зона которого обслуживается Timeweb. Ниже он `example.com`,
  а проекты живут на `<app>.sandbox.example.com`.
- API-токен Timeweb Cloud (панель → API-ключи) с правом менять DNS-записи:
  Caddy создаёт TXT-запись `_acme-challenge` для wildcard-сертификата.

**Твоя машина**
- Docker с Compose, git, python3, bash.
- Клон этого репозитория.

## 1. Подготовить образы на своей машине

Образы Caddy и worker на VPS не собираются: их собирают один раз у себя и
переносят архивом, контрольная сумма которого проверяется на сервере.

```bash
git clone <URL-этого-репозитория> sandbox-infra && cd sandbox-infra
docker build -t sandbox-caddy:candidate caddy/
docker build -t sandbox-worker:candidate worker/
```

- **Caddy** — сборка Caddy с плагинами `caddy-docker-proxy` (маршруты из
  Docker labels) и `caddy-dns/timeweb` (DNS-01). Версии и базовые образы
  закреплены в `caddy/Dockerfile`.
- **worker** — Node 22 с компилятором для нативных модулей; в нём
  собираются Node-проекты.

### Скан (рекомендуется)

```bash
scripts/scan-image.sh sandbox-caddy:candidate caddy
scripts/scan-image.sh sandbox-worker:candidate worker
python3 scripts/check-release.py
```

`scan-image.sh` запускает Trivy и Syft из образов, закреплённых по digest,
и записывает скан, SBOM и число находок в
`docs/security-remediation/release-manifest.json`. `check-release.py`
показывает, что мешает выпуску: находки HIGH/CRITICAL без исправления
нужно либо исправить (обновить базовый образ), либо оформить исключением в
`docs/security-remediation/exceptions.json` — с причиной, владельцем и сроком
не дольше 90 дней. Для находки, у которой есть исправленная версия,
исключение не принимается. Одобрение (`approved`) ставишь ты сам.

### Экспорт

```bash
scripts/export-image.sh sandbox-caddy:candidate caddy.tar --artifact caddy
scripts/export-image.sh sandbox-worker:candidate worker.tar --artifact worker
```

Каждая команда печатает SHA-256 архива — сохрани обе суммы. С `--artifact`
скрипт откажется экспортировать образ, если это не тот, что сканировался, и
запишет архив в манифест. Без скана запускай без `--artifact`.

## 2. Установить на VPS

```bash
scp -r sandbox-infra caddy.tar worker.tar root@<IP>:/root/
ssh root@<IP>
cd /root/sandbox-infra
SANDBOX_CADDY_ARCHIVE=/root/caddy.tar \
SANDBOX_CADDY_ARCHIVE_SHA256=<sha256 caddy.tar> \
    ./bootstrap.sh
```

Если образ Caddy лежит в registry, вместо двух переменных архива подойдёт
`SANDBOX_CADDY_IMAGE='<registry>/<image>@sha256:<digest>'`.

Что делает bootstrap по порядку:

1. Создаёт пользователя `deploy` — от него идут `git push` и деплой.
2. Ставит Docker, Compose, rsync, git, python3 с PyYAML, curl, util-linux.
3. Создаёт `/srv/{git,apps,sites,state,deploy,caddy}` и
   `/etc/sandbox/projects` (root-политики проектов).
4. На чистом Docker включает **userns-remap**: root в контейнерах проектов
   становится непривилегированным UID хоста. Если в Docker уже есть
   контейнеры или тома, шаг пропускается — перенос делается по runbook.
5. Создаёт сети `sandbox_net` (Caddy ↔ проекты) и `sandbox_build` (скачивание
   npm-зависимостей worker'ом).
6. Ставит скрипты в `/srv/deploy` от root, включает
   `sandbox-maintenance.timer` (ежедневная очистка) и
   `sandbox-firewall.service` (контейнеры не видят хост и частные сети).
7. Создаёт `/srv/sandbox.conf`, `/srv/caddy/config/Caddyfile`,
   `/srv/caddy/docker-compose.yml`, `/srv/caddy/.env` (`root:deploy 0640`).
8. Проверяет SHA-256 архива Caddy, загружает образ и записывает его ID в
   `/srv/caddy/.env`; запускает Caddy.
9. Включает автоматические обновления безопасности и — если у root уже есть
   ключ в `/root/.ssh/authorized_keys` — отключает вход по паролю.

Необязательные переменные:

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `SANDBOX_USERNS_REMAP` | `true` | `false` — не включать userns-remap |
| `SANDBOX_AUTO_REBOOT` | `true` | `false` — не перезагружать сервер после обновления ядра |
| `SANDBOX_REBOOT_TIME` | `04:30` | время такой перезагрузки |
| `SANDBOX_SSH_HARDENING` | `true` | `false` — не трогать настройки SSH |

## 3. Донастроить вручную

1. **Домен и email.** В `/srv/caddy/config/Caddyfile` замени домен в трёх
   местах: `*.sandbox.example.com`, голый `sandbox.example.com` и
   регулярное выражение `\.sandbox\.example\.com$` (там точки экранированы:
   `\.sandbox\.твой-домен\.ru$`). `you@example.com` замени на свой email для
   Let's Encrypt. В `/srv/sandbox.conf`
   впиши `SANDBOX_DOMAIN=sandbox.<твой домен>` и `SANDBOX_SSH_HOST` — адрес,
   по которому ты заходишь на сервер по SSH.
2. **Токен.** В `/srv/caddy/.env` впиши `TIMEWEB_API_TOKEN=…`. Строку
   `SANDBOX_CADDY_IMAGE` не трогай — её записал bootstrap.
3. **DNS.** В зоне `example.com` в Timeweb добавь две A-записи на IP VPS:
   ```
   *.sandbox   A   <IP>
   sandbox     A   <IP>     (отдельно: wildcard не покрывает сам sandbox)
   ```
4. **Перезапусти Caddy:**
   ```bash
   cd /srv/caddy && docker compose up -d --force-recreate
   ```
5. **Ключи SSH.** Свой публичный ключ — в `/home/deploy/.ssh/authorized_keys`
   (от `deploy` идут push и клиент). Если bootstrap написал «у root нет
   ключа», добавь ключ и в `/root/.ssh/authorized_keys` и запусти
   `/srv/deploy/harden-host.sh` — он отключит вход по паролю.
6. **Worker.** Загрузи образ worker:
   ```bash
   /srv/deploy/load-image.sh /root/worker.tar <sha256 worker.tar>
   ```
   Команда печатает ID вида `sha256:…` — он нужен в политиках Node-проектов
   ([deploy-node.md](deploy-node.md)).

## 4. Проверить

```bash
curl -s https://sandbox.example.com           # «Sandbox root — see project subdomains»
curl -s https://nothing.sandbox.example.com   # «Unknown sandbox project» (404)
systemctl list-timers sandbox-maintenance.timer
systemctl status sandbox-firewall.service
docker run --rm busybox cat /proc/self/uid_map   # не «0 0 …», если remap включён
```

Первый запрос к `*.sandbox` может занять до минуты: Caddy получает
wildcard-сертификат. Ошибки выпуска видно в `docker compose logs caddy`
(в `/srv/caddy`).

## 5. Настроить клиент на своей машине

`client/sandbox-deploy` — удобная обёртка над SSH-командами: создаёт проект,
пушит и проверяет, что деплой действительно прошёл.

```bash
mkdir -p ~/.config/sandbox-deploy
echo 'SANDBOX_HOST=deploy@<адрес VPS>' > ~/.config/sandbox-deploy/config
cp client/sandbox-deploy ~/.local/bin/    # или любой каталог из PATH
```

Дальше — по типу проекта:
[статика](deploy-static.md), [Node/SPA](deploy-node.md),
[Docker](deploy-docker.md).

## Обновление

**Скрипты и конфигурация.** На VPS в клоне репозитория:

```bash
git pull
sudo ./update-infra.sh --dry-run
sudo ./update-infra.sh
```

`update-infra.sh` ставит новые скрипты в `/srv/deploy`, обновляет
systemd-юниты, переносит домен и email из действующего Caddyfile в новый
шаблон, показывает diff, делает бэкап в `/root/sandbox-backups/` и
откатывается, если `caddy validate` не прошёл. `.env`, проекты и релизы не
трогаются. userns-remap и закалку хоста он сам не включает.

**Образы.** Новый образ собери, отсканируй и экспортируй так же, как в
шаге 1, перенеси архив и загрузи:

```bash
sudo /srv/deploy/load-image.sh caddy.tar <sha256> --caddy   # пишет ID в /srv/caddy/.env
cd /srv/caddy && docker compose up -d
sudo /srv/deploy/load-image.sh worker.tar <sha256>          # ID — в политики Node-проектов
```

Пересматривать образы стоит раз в месяц: исключения в `exceptions.json`
выдаются на 30 дней.

## Обслуживание

- `sandbox-maintenance.timer` раз в сутки запускает
  `/srv/deploy/maintenance.sh`: чистит завершённые логи деплоев, остатки
  прерванных деплоев, делает `git gc --auto`, удаляет недельный кеш сборки
  Docker и старые бэкапы миграции. Если свободного места меньше 2 ГБ, юнит
  завершается с ошибкой — это видно в `systemctl --failed`. Посмотреть план:
  `sudo /srv/deploy/maintenance.sh --dry-run`.
- Деплой не начнётся, если свободно меньше 1 ГБ (`SANDBOX_MIN_FREE_MB`).
- Firewall переустанавливается при каждом старте Docker; руками —
  `sudo /srv/deploy/firewall.sh`.
- Права закрытого состояния чинит `sudo /srv/deploy/repair-permissions.sh`
  (есть `--dry-run`).

## Если что-то не работает

| Симптом | Что проверить |
|---|---|
| bootstrap: «SHA-256 архива не совпадает» | архив повредился при копировании или сумма от другого файла — повтори `sha256sum` у себя и на VPS |
| сертификат для `*.sandbox` не выпускается | токен Timeweb, права на DNS, запись `*.sandbox`; `docker compose logs caddy` |
| `https://sandbox.<домен>` не открывается | отдельная A-запись `sandbox`, порты 80/443 в firewall провайдера |
| push проходит, но «ДЕПЛОЙ ПРОВАЛЕН» | `sandbox-deploy logs <app>`: полный лог сборки этого коммита |
| «деплой отложен: на диске мало места» | `df -h`, `sudo /srv/deploy/maintenance.sh` |
| Node: «root-owned execution policy required» | нет `/etc/sandbox/projects/<app>.conf` — см. [deploy-node.md](deploy-node.md) |
| Docker: «не допущен политикой» | нет политики `profile=compose` — см. [deploy-docker.md](deploy-docker.md) |
