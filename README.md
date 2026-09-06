# Sandbox-инфраструктура для VPS

Git-push деплой для статики, SPA и Docker-приложений через один общий
post-receive хук и Caddy с автоматическим TLS (DNS-01, Timeweb).

## Проверено в бою

Вся инфраструктура протестирована end-to-end на реальном VPS (Timeweb) для
статики, React/Vite-сборки и Docker-контейнера с лейблами — все три сценария
подтверждены рабочими. По пути исправлены нюансы, которые стоит знать:

- Флаг `caddy docker-proxy` нужен именно с двойным дефисом
  (`--caddyfile-path`), одиночный дефис парсер трактует как склейку
  однобуквенных флагов.
- DNS-01 challenge (`dns timeweb ...`) должен быть указан **только** внутри
  wildcard-блока, не глобально — иначе apex-домен и wildcard одновременно
  просят DNS-01 по одному и тому же имени `_acme-challenge`, и возникает
  гонка TXT-записей. Apex-домен и так проходит через обычный HTTP-01.
- Плейсхолдер `{labels.N}` в Caddy считает части домена **с конца**, а не
  с начала (`{labels.0}` для `test.sandbox.example.com` — это `com`, а не
  `test`). Вместо этого используется `header_regexp` с явным regex-захватом
  поддомена, и матчер обязательно навешивается на директиву (`root @app ...`),
  иначе он объявлен, но не выполняется, и плейсхолдер остаётся пустым.
- `npm ci` требует существующий `package-lock.json` — хук проверяет его
  наличие и падает обратно на `npm install`, если лок-файла нет.
- Node.js на VPS по умолчанию не установлен — `bootstrap.sh` теперь ставит
  Node LTS через NodeSource.

## Структура репозитория

```
bootstrap.sh          — разовая установка всего на чистый VPS
caddy/
  Dockerfile           — сборка Caddy через xcaddy (docker-proxy + timeweb)
  docker-compose.yml   — запуск Caddy
  Caddyfile             — конфиг Caddy (домен и email — placeholder'ы)
  .env.example          — шаблон для TIMEWEB_API_TOKEN
deploy/
  hook.sh                — общий post-receive хук, определяет тип проекта и деплоит
  new-app.sh              — создание нового bare-репозитория на VPS
  stop-app.sh              — временная остановка проекта
  remove-app.sh             — полное удаление проекта
client/
  sandbox-deploy           — локальный интерактивный клиент (см. ниже)
```

## Установка на чистый VPS

```bash
git clone <URL-этого-репозитория> sandbox-infra
scp -r sandbox-infra root@<VPS-IP>:/root/
ssh root@<VPS-IP>
cd /root/sandbox-infra
chmod +x bootstrap.sh
./bootstrap.sh
```

После этого вручную:

1. В `/srv/caddy/Caddyfile` замени `sandbox.example.com` на свой домен.
2. В `/srv/caddy/.env` впиши `TIMEWEB_API_TOKEN` (Timeweb Cloud → API-ключи).
3. Перезапусти Caddy:
   ```bash
   cd /srv/caddy && docker compose up -d --force-recreate
   ```
4. В DNS-зоне Timeweb добавь записи:
   ```
   A   *.sandbox     -> <IP VPS>
   A   sandbox       -> <IP VPS>   (отдельная запись, wildcard её не покрывает)
   ```
5. Добавь свой публичный SSH-ключ в `/home/deploy/.ssh/authorized_keys`.

## Создание нового проекта

```bash
/srv/deploy/new-app.sh myapp
```

Скрипт выведет команду для добавления remote — выполни её у себя локально
в репозитории проекта, дальше просто `git push prod main`.

## Остановка и удаление проекта

```bash
/srv/deploy/stop-app.sh myapp     # временно остановить, данные сохраняются
/srv/deploy/remove-app.sh myapp   # удалить полностью и необратимо
```

`stop-app.sh` останавливает Docker-контейнеры (`docker compose down`) или
убирает статику из `/srv/sites/<app>` — в обоих случаях bare-репозиторий не
трогается, и обычный `git push prod main` поднимает проект заново.

`remove-app.sh` сносит всё: bare-репозиторий, рабочий чекаут, статику и (для
Docker-проектов) контейнеры/volumes/локально собранные образы. Спрашивает
подтверждение, если не передан флаг `--force`/`-y`.

## Локальный клиент `client/sandbox-deploy`

Интерактивный bash-скрипт для машины разработчика — избавляет от ручного
логина по SSH при создании нового проекта.

Что делает:
- Определяет имя проекта по имени текущей папки (можно переопределить
  аргументом).
- Одним SSH-вызовом идемпотентно проверяет/создаёт bare-репозиторий на VPS.
- Добавляет/обновляет `git remote` в текущей папке.
- Предупреждает, если текущая ветка не `main` (хук на сервере ждёт именно её).
- Для Docker-проектов проверяет наличие лейблов `caddy:` и предупреждает,
  если их нет.
- Интерактивно спрашивает про немедленный push.
- Подкомандами `stop`/`remove` дёргает соответствующие скрипты на VPS одним
  SSH-вызовом (для `remove` подтверждение запрашивается локально, чтобы не
  зависеть от интерактивного ввода через SSH-хередок).

Настройка (без хардкода хоста в самом скрипте — его можно спокойно класть
в публичный репозиторий со своими скриптами):

```bash
mkdir -p ~/.config/sandbox-deploy
echo 'SANDBOX_HOST=deploy@sandbox.example.com' > ~/.config/sandbox-deploy/config
```

Использование:

```bash
sandbox-deploy                # имя проекта = имя текущей папки
sandbox-deploy myapp          # явное имя проекта
sandbox-deploy myapp --push   # создать + сразу запушить
sandbox-deploy stop [myapp]   # временно остановить
sandbox-deploy remove [myapp] # полностью и необратимо удалить
```

## Как деплоится каждый тип проекта

### 1. Статика (html/js без фреймворков)
Ничего добавлять не нужно. Хук видит отсутствие `Dockerfile`/`package.json`
и просто копирует содержимое репозитория в `/srv/sites/<app>/`, откуда
раздаёт Caddy. Доступен на `<app>.sandbox.<домен>` сразу после пуша.

### 2. React/SPA (опционально с backend+БД)
- Если это чистый фронт без своего сервера — просто `package.json` со
  скриптом `build`. Хук сам собирает (`npm run build`) и раздаёт как
  статику.
- Если есть backend и БД — нужен `docker-compose.yml`, см. пункт 3.

### 3. Приложение в Docker с фронтом
Добавь в репозиторий `docker-compose.yml` с лейблами:
```yaml
services:
  app:
    build: .
    labels:
      caddy: myapp.sandbox.example.com
      caddy.reverse_proxy: "{{upstreams 80}}"
    networks:
      - sandbox_net

networks:
  sandbox_net:
    external: true
```
`caddy-docker-proxy` сам увидит новый контейнер и подключит роутинг —
Caddyfile трогать не нужно.

### 4. REST API без фронтенда
То же самое, что пункт 3, просто другой внутренний порт в
`caddy.reverse_proxy`. Например: `"{{upstreams 8080}}"`.

### 5. Контейнер без внешнего входа (например, тг-бот)
```yaml
services:
  bot:
    build: .
    restart: unless-stopped
    env_file: .env
    networks:
      - sandbox_net
```
Без `ports:` и без лейблов `caddy:` — контейнер просто поднимается и сам
стучится наружу, снаружи к нему обращаться не нужно.

`.env` с секретами (токен бота и т.п.) кладётся один раз вручную в
`/srv/apps/<app>/.env` — в git не коммитится.

## Изоляция сети между сервисами одного проекта

Если внутри проекта несколько контейнеров и часть из них не должна быть
видна снаружи — используй отдельную локальную сеть вдобавок к `sandbox_net`:

```yaml
services:
  frontend:
    build: ./frontend
    labels:
      caddy: myapp.sandbox.example.com
      caddy.reverse_proxy: "{{upstreams 80}}"
    networks:
      - sandbox_net
      - backend_net

  api:
    build: ./api
    networks:
      - backend_net    # не в sandbox_net -> недоступен снаружи

  db:
    image: postgres:16
    networks:
      - backend_net

networks:
  sandbox_net:
    external: true
  backend_net:
    driver: bridge
```

## Пока не реализовано (отложено)

- Не-HTTP TCP-протоколы (нужен `caddy-l4` или прямой проброс портов).
- Процессы без Docker через systemd unit-файлы.

Оба легко добавляются как дополнительные ветки в `deploy/hook.sh`, когда
понадобятся.
