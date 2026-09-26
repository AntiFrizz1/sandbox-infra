**Русский** | [English](../en/deploy-docker.md)

# Деплой Docker-проекта (backend, API, база, бот)

Всё, что должно работать постоянно: сервер на Node/Python/Go, SSR, база
данных, Telegram-бот. Проект описывается compose-файлом в репозитории, хук
запускает его как `docker compose -p <app> up -d --build`, а Caddy
публикует сервисы по лейблам.

Compose исполняет Docker-демон хоста, поэтому проект допускается только по
root-политике и только после проверки compose-файла по белому списку.

## 1. Разрешить проект на сервере (один раз, root)

```bash
sudo install -m 644 -o root -g root \
    /root/sandbox-infra/examples/compose-policy.conf /etc/sandbox/projects/my-api.conf
```

| Ключ | По умолчанию | Смысл |
|---|---|---|
| `profile` | — | всегда `compose` |
| `timeout_seconds` | 900 | предел `docker compose up -d --build` |
| `memory_mb` | 512 | память **каждого** сервиса |
| `pids` | 256 | процессы каждого сервиса |
| `cpus` | 1 | CPU каждого сервиса |

Таймаут останавливает CLI, но сборку, уже переданную демону, не прерывает.
Без политики хук отвечает «Docker-проект не допущен политикой» и ничего не
запускает — даже если в коммите сменили `type`.

## 2. Репозиторий

```
my-api/
├── compose.yml          ← или docker-compose.yml / .yaml, compose.yaml
├── Dockerfile
├── src/ …
└── .sandbox.conf        ← необязательно (пример — examples/docker.sandbox.conf)
```

```
type=docker
health_url=https://my-api.sandbox.example.com/health   # необязательно
```

Проект с compose-файлом распознаётся как Docker и без `.sandbox.conf`.
Одного `Dockerfile` мало: без compose-файла деплой остановится с
объяснением.

## 3. compose-файл

Минимальный веб-сервис:

```yaml
services:
  app:
    build: .
    labels:
      caddy: my-api.sandbox.example.com
      caddy.reverse_proxy: "{{upstreams 8080}}"
    networks: [sandbox_net]
networks:
  sandbox_net:
    external: true
```

- Сервис, доступный снаружи, должен быть в сети `sandbox_net` и иметь два
  лейбла. `caddy` — адрес или список адресов, только `my-api.<домен>` и его
  поддомены (`api.my-api.<домен>`). `caddy.reverse_proxy` — ровно
  `{{upstreams}}` или `{{upstreams <порт>}}`, порт — внутренний порт
  контейнера. Сертификат для адреса Caddy получит сам.
- `ports:` запрещены: наружу всё идёт через Caddy.

Сервис с базой и внутренней сетью:

```yaml
services:
  web:
    build: .
    labels:
      caddy: my-api.sandbox.example.com
      caddy.reverse_proxy: "{{upstreams 3000}}"
    env_file: .env
    networks: [sandbox_net, backend]
    depends_on: [db]
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - dbdata:/var/lib/postgresql/data
    networks: [backend]          # не в sandbox_net — снаружи не виден
volumes:
  dbdata:
networks:
  sandbox_net:
    external: true
  backend: {}
```

Бот без входящего HTTP — без лейблов и без `sandbox_net`:

```yaml
services:
  bot:
    build: .
    restart: unless-stopped
    env_file: .env
```

## Секреты

Runtime-секреты клади на сервер в `/srv/state/<app>/env` (формат `.env`,
`0600`, владелец deploy). При деплое файл копируется в рабочий каталог как
`.env` — его читает `env_file: .env`. Это же единственный источник
подстановок `${VAR}` в compose-файле: `.env` из репозитория и окружение
пользователя deploy для подстановки не используются. В git секреты не клади.
Если сервис ссылается на `env_file: .env`, а файла на сервере нет (и в
репозитории тоже), compose остановится с ошибкой — создай хотя бы пустой
`/srv/state/<app>/env`.

## Что проверяется перед запуском

`deploy/lint-compose.py` проверяет итоговую модель compose (со всеми
профилями) и сам файл. Разрешено всё обычное: `image`, `build` (context и
Dockerfile внутри проекта), `command`, `environment`, `env_file`,
`depends_on`, `healthcheck`, `restart`, именованные тома, `tmpfs`, свои
bridge-сети, `user`, `read_only`, `cap_drop`, резервы ресурсов.

Отвергается:

| Что | Почему |
|---|---|
| `privileged`, `cap_add`, `devices`, `sysctls` | лишние права ядра |
| `network_mode`, `pid`, `ipc`, `userns_mode` хоста | выход из изоляции контейнера |
| `security_opt` кроме `no-new-privileges` | отключение seccomp/AppArmor |
| bind-mount и `env_file` вне каталога проекта (в том числе через симлинк), Docker socket | доступ к файлам хоста |
| внешние тома, тома с `name:` или `driver_opts`, `volumes_from` | чужие данные |
| внешние сети, кроме `sandbox_net`; сети с `name:`, `ipam`, не-bridge драйвер | сеть управления Caddy, чужие проекты |
| `ports`, `container_name` | публикация мимо Caddy, конфликт имён |
| `logging`, лимиты ресурсов (`mem_limit`, `cpus`, `deploy.resources.limits` и т. п.) | их задаёт сервер |
| `include`, `extends` из другого файла, `secrets`, `configs` | чтение файлов хоста |
| build с `ssh`, `additional_contexts`, `network`, `cache_from` | доступ к хосту из сборки |
| образ со сборкой, названный не `my-api-…` | подмена чужого образа |
| лейблы `caddy*`, кроме `caddy` и `caddy.reverse_proxy` в формате выше; `com.docker.*` | чужие адреса, директивы в публичный Caddy |

Сообщение об отказе начинается с `compose policy:` и называет сервис и
ключ. Работающий стек при отказе не трогается.

## Что добавляет сервер

К каждому сервису серверный override добавляет:

- лимиты памяти (без swap), CPU и числа процессов из политики;
- `no-new-privileges`;
- ротацию логов (`local`, 3 × 10 МБ);
- отказ от capabilities `NET_RAW`, `MKNOD`, `SYS_CHROOT`, `SETFCAP`,
  `AUDIT_WRITE` — обычным сервисам они не нужны.

И действует для всех контейнеров:

- **userns-remap** (если включён): root в контейнере — непривилегированный
  UID хоста. Каталог, в который сервис пишет через bind-mount, должен
  принадлежать сдвинутому UID; проще держать такие данные в именованных
  томах — Docker выставит права сам.
- **firewall**: из контейнеров не видны сам сервер, частные сети
  (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`) и метаданные облака.
  Интернет доступен. База на хосте или в частной сети провайдера недоступна —
  держи её в compose проекта.

## Деплой и управление

```bash
sandbox-deploy init my-api
sandbox-deploy push
```

При каждом push хук копирует коммит в `/srv/apps/<app>` (без удаления
файлов — данные в bind-mount'ах сохраняются), подкладывает `.env`,
проверяет compose-файл, пишет override и выполняет
`docker compose -p <app> up -d --build --remove-orphans`. Если задан
`health_url` (только `https://<app>.<домен>/…`), хук ждёт ответа до 60
секунд. Имя compose-проекта всегда `<app>`, поэтому тома переживают
передеплой.

```bash
sandbox-deploy status my-api     # коммит, запущенный в контейнерах
sandbox-deploy logs my-api       # лог деплоя (не логи приложения)
sandbox-deploy stop my-api       # docker compose -p my-api down, тома остаются
sandbox-deploy remove my-api     # down -v --rmi local: контейнеры, тома, образы
```

`stop` и `remove` работают по имени проекта и не читают compose-файл.
Откат для Docker-проекта — push нужного коммита (`rollback` переключает
только релизы статики). Логи самого приложения смотри на сервере:
`docker compose -p my-api logs`.

## Если что-то не так

| Сообщение | Что делать |
|---|---|
| «Docker-проект не допущен политикой» | нет `/etc/sandbox/projects/<app>.conf` с `profile=compose` |
| `compose policy: …` | исправь названный ключ; таблица выше |
| «docker compose config failed» | синтаксис compose-файла или неизвестная переменная |
| «health_url должен вести на …» | адрес проверки — только через Caddy на домене проекта |
| «приложение не ответило … за отведённое время» | сервис не поднялся: `docker compose -p <app> logs` |
| приложение не может писать в `./data` | userns-remap: используй именованный том или передай каталог сдвинутому UID |
| приложение не видит базу на хосте | так и задумано (firewall): база в compose проекта |
