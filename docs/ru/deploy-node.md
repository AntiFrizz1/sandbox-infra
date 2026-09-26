**Русский** | [English](../en/deploy-node.md)

# Деплой Node-проекта со сборкой (Vite, React, Vue, SPA)

Фронтенд, который нужно собрать: `npm ci && npm run build`, результат —
статические файлы. Сборка идёт в одноразовом изолированном контейнере
(worker), а результат публикуется так же, как [статика](deploy-static.md).

Серверный Node (Express, Next.js в режиме сервера, API) так не работает:
после сборки процесс не запускается. Для него —
[Docker-проект](deploy-docker.md).

## 1. Разрешить проект на сервере (один раз, root)

Код сборки — чужой по определению (зависимости из npm), поэтому что и как
можно запускать, решает root-политика, а не репозиторий.

```bash
sudo install -m 644 -o root -g root \
    /root/sandbox-infra/examples/worker-policy.conf /etc/sandbox/projects/my-app.conf
sudo nano /etc/sandbox/projects/my-app.conf
```

Обязательно заполни `image=` — ID образа worker, который напечатал
`load-image.sh` при [установке](install.md#3-донастроить-вручную), например
`image=sha256:1b56…`. Теги не принимаются.

| Ключ | По умолчанию | Смысл |
|---|---|---|
| `profile` | — | всегда `worker` |
| `image` | — | `sha256:…` ID или `<registry>/<image>@sha256:…` |
| `timeout_seconds` | 300 | предел каждой из двух фаз |
| `memory_mb` | 512 | память контейнера (без swap) |
| `pids` | 128 | предел процессов |
| `cpus` | 1 | CPU |
| `output_mb` | 2048 | предел дерева сборки (исходники, `node_modules`, результат) |
| `fetch_network` | `none` в коде, `sandbox_build` в примере | сеть для скачивания зависимостей; только `none` или сеть с меткой `sandbox.role=build` |
| `npm_registry` | `https://registry.npmjs.org/` | registry для npm; перекрывает `.npmrc` проекта |

Файл и все каталоги над ним должны принадлежать root и не быть доступны на
запись группе и остальным — иначе политика отвергается. Без политики сборка
не запускается («root-owned execution policy required»), а на хосте она не
запускается никогда.

## 2. Репозиторий

```
my-app/
├── package.json         ← скрипт "build"
├── package-lock.json    ← рекомендуется: тогда npm ci, воспроизводимо
├── src/ …
└── .sandbox.conf
```

`.sandbox.conf` (пример — `examples/vite.sandbox.conf`):

```
type=node
build_cmd=npm run build
publish_dir=dist        # Create React App: build
spa=true                # маршрутизация в браузере
```

Без `.sandbox.conf` проект с `package.json` считается Node-проектом с
`build_cmd=npm run build` и `publish_dir=dist`.

## 3. Деплой

```bash
sandbox-deploy init my-app
sandbox-deploy push
```

или `ssh deploy@<VPS> /srv/deploy/new-app.sh my-app`, `git remote add prod …`,
`git push prod main` — как для [статики](deploy-static.md#первый-деплой).

## Как идёт сборка

Два одноразовых контейнера с общим каталогом `/work`:

1. **fetch** — сеть из `fetch_network`, исходники только для чтения.
   Копирует их в `/work` и выполняет `npm ci --ignore-scripts` (или
   `npm install --ignore-scripts` без lock-файла). npm только скачивает и
   распаковывает пакеты: ни код проекта, ни скрипты зависимостей не
   выполняются, пока есть сеть.
2. **build** — без сети и без доступа к исходникам. `npm rebuild` (скрипты
   установки зависимостей, сборка нативных модулей через node-gyp по
   заголовкам из образа), затем скрипты проекта `preinstall`, `install`,
   `postinstall`, `prepare` и `build_cmd`.

Оба контейнера: корень только для чтения, без capabilities, с
`no-new-privileges`, от UID пользователя deploy, без доступа к `/srv`,
SSH-ключам и Docker API, с лимитами из политики. Если дерево сборки
превышает `output_mb` или на диске остаётся меньше 1 ГБ, контейнер
останавливается. Затем `publish_dir` публикуется как новый релиз — с теми же
исключениями, что у статики (dot-файлы, `.env`, ключи, корневой
`node_modules`).

## Секреты сборки

Переменные, которые нужны во время сборки (например, публичный ключ API для
фронтенда), клади в `/srv/state/<app>/build-env` (формат `.env`, права
`0600`, владелец deploy). Файл доступен только фазе build и копируется в
`/work/.env` — Vite и похожие инструменты читают его сами. Помни: всё, что
попало в собранный фронтенд, увидит любой посетитель, а код зависимостей
видит весь файл. Runtime-секреты (`/srv/state/<app>/env`) Node-сборка не
получает.

## Ограничения

- **Git-зависимости не работают**: в образе нет git.
- **Пакеты, которые в postinstall что-то скачивают** (Puppeteer с Chromium,
  Cypress, Electron), падают: в фазе build нет сети. Отключи скачивание
  настройкой самого пакета или не держи такие пакеты в зависимостях
  фронтенда.
- **Сборка, которая ходит в сеть** (загрузка шрифтов, запросы к API во время
  `build`), тоже не сработает.
- **Приватный registry** задаётся в политике (`npm_registry`). Registry в
  частной сети провайдера закрыт firewall'ом.

## Управление

Те же команды, что для статики: `status`, `logs`, `rollback`, `redeploy`,
`stop`, `remove` — см. [deploy-static.md](deploy-static.md#управление).
Лог сборки конкретного коммита — `sandbox-deploy logs my-app <sha>` (до 1 МиБ).

## Если что-то не так

| Сообщение | Что делать |
|---|---|
| «root-owned execution policy required» | нет политики или у неё неверные права/владелец |
| «image must be repo@sha256:… or a local sha256:… ID» | в политике тег или пусто в `image=` |
| «fetch_network must be none or a network labelled …» | сеть не существует или без метки `sandbox.role=build` |
| «worker fetch failed» | смотри лог: чаще всего lock-файл не совпадает с `package.json` или нет сети (`fetch_network=none`) |
| «worker build failed» | ошибка сборки проекта или пакет пытался скачать что-то без сети |
| «worker … stopped: output …» | превышен `output_mb` или кончается место |
| «failed/timeout (137)» | не хватило памяти (`memory_mb`) |
| «каталог публикации 'dist' непригоден» | сборка кладёт результат не в `dist` — поправь `publish_dir` |
