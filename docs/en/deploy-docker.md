[Русский](../ru/deploy-docker.md) | **English**

# Deploying a Docker project (backend, API, database, bot)

Anything that has to keep running: a Node/Python/Go server, SSR, a
database, a Telegram bot. The project is described by a compose file in the
repository; the hook runs it as `docker compose -p <app> up -d --build`, and
Caddy publishes services by their labels.

Compose is executed by the host's Docker daemon, so a project is admitted
only with a root policy and only after its compose file passes an allowlist
check.

## 1. Allow the project on the server (once, as root)

```bash
sudo install -m 644 -o root -g root \
    /root/sandbox-infra/examples/compose-policy.conf /etc/sandbox/projects/my-api.conf
```

| Key | Default | Meaning |
|---|---|---|
| `profile` | — | always `compose` |
| `timeout_seconds` | 900 | limit for `docker compose up -d --build` |
| `memory_mb` | 512 | memory of **each** service |
| `pids` | 256 | processes of each service |
| `cpus` | 1 | CPU of each service |

The timeout stops the CLI but does not interrupt a build already handed to
the daemon. Without a policy the hook answers "Docker-проект не допущен
политикой" (Docker project not admitted by policy) and runs nothing — even
if a commit changed `type`.

## 2. Repository

```
my-api/
├── compose.yml          ← or docker-compose.yml / .yaml, compose.yaml
├── Dockerfile
├── src/ …
└── .sandbox.conf        ← optional (example: examples/docker.sandbox.conf)
```

```
type=docker
health_url=https://my-api.sandbox.example.com/health   # optional
```

A project with a compose file is detected as Docker without
`.sandbox.conf`. A `Dockerfile` alone is not enough: without a compose file
the deploy stops with an explanation.

## 3. The compose file

A minimal web service:

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

- A service reachable from outside must be on `sandbox_net` and carry two
  labels. `caddy` is an address or a list of addresses, only `my-api.<domain>`
  and its subdomains (`api.my-api.<domain>`). `caddy.reverse_proxy` is
  exactly `{{upstreams}}` or `{{upstreams <port>}}`, where the port is the
  container's internal port. Caddy obtains the certificate for the address.
- `ports:` is not allowed: everything from outside goes through Caddy.

A service with a database and an internal network:

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
    networks: [backend]          # not on sandbox_net — invisible from outside
volumes:
  dbdata:
networks:
  sandbox_net:
    external: true
  backend: {}
```

A bot without incoming HTTP — no labels and no `sandbox_net`:

```yaml
services:
  bot:
    build: .
    restart: unless-stopped
    env_file: .env
```

## Secrets

Put runtime secrets on the server in `/srv/state/<app>/env` (`.env` format,
`0600`, owned by deploy). On deploy the file is copied into the working
directory as `.env`, which `env_file: .env` reads. It is also the only source
for `${VAR}` substitution in the compose file: neither the repository's
`.env` nor the deploy user's environment is used for substitution. Keep
secrets out of git. If a service refers to `env_file: .env` and there is no
such file on the server (nor in the repository), compose stops with an error
— create at least an empty `/srv/state/<app>/env`.

## What is checked before start

`deploy/lint-compose.py` checks the rendered compose model (all profiles)
and the file itself. Everything ordinary is allowed: `image`, `build`
(context and Dockerfile inside the project), `command`, `environment`,
`env_file`, `depends_on`, `healthcheck`, `restart`, named volumes, `tmpfs`,
your own bridge networks, `user`, `read_only`, `cap_drop`, resource
reservations.

Refused:

| What | Why |
|---|---|
| `privileged`, `cap_add`, `devices`, `sysctls` | extra kernel privileges |
| host `network_mode`, `pid`, `ipc`, `userns_mode` | leaving container isolation |
| `security_opt` other than `no-new-privileges` | turning off seccomp/AppArmor |
| bind mounts and `env_file` outside the project directory (symlinks included), the Docker socket | host file access |
| external volumes, volumes with `name:` or `driver_opts`, `volumes_from` | other projects' data |
| external networks other than `sandbox_net`; networks with `name:`, `ipam`, a non-bridge driver | the Caddy control network, other projects |
| `ports`, `container_name` | publishing around Caddy, name clashes |
| `logging`, resource limits (`mem_limit`, `cpus`, `deploy.resources.limits`, …) | the server sets them |
| `include`, `extends` from another file, `secrets`, `configs` | reading host files |
| build with `ssh`, `additional_contexts`, `network`, `cache_from` | host access from the build |
| a built image not named `my-api-…` | replacing someone else's image |
| `caddy*` labels other than `caddy` and `caddy.reverse_proxy` in the form above; `com.docker.*` | foreign addresses, directives injected into the public Caddy |

A refusal message starts with `compose policy:` and names the service and
key. A refusal leaves the running stack untouched.

## What the server adds

A server-side override adds to every service:

- memory (no swap), CPU and process limits from the policy;
- `no-new-privileges`;
- log rotation (`local`, 3 × 10 MB);
- dropping the `NET_RAW`, `MKNOD`, `SYS_CHROOT`, `SETFCAP`, `AUDIT_WRITE`
  capabilities — ordinary services do not need them.

And for all containers:

- **userns-remap** (when enabled): root in a container is an unprivileged
  host UID. A directory a service writes to through a bind mount must belong
  to the shifted UID; it is simpler to keep such data in named volumes —
  Docker sets their ownership itself.
- **firewall**: containers cannot see the server itself, private networks
  (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`) or cloud metadata. The
  internet is reachable. A database on the host or in the provider's private
  network is out of reach — keep it in the project's compose file.

## Deploy and management

```bash
sandbox-deploy init my-api
sandbox-deploy push
```

On every push the hook copies the commit into `/srv/apps/<app>` (without
deleting files — data in bind mounts survives), places `.env`, checks the
compose file, writes the override and runs
`docker compose -p <app> up -d --build --remove-orphans`. With `health_url`
set (only `https://<app>.<domain>/…`), the hook waits up to 60 seconds for
an answer. The compose project name is always `<app>`, so volumes survive
redeploys.

```bash
sandbox-deploy status my-api     # the commit running in the containers
sandbox-deploy logs my-api       # the deploy log (not the application log)
sandbox-deploy stop my-api       # docker compose -p my-api down, volumes stay
sandbox-deploy remove my-api     # down -v --rmi local: containers, volumes, images
```

`stop` and `remove` act on the project name and do not read the compose
file. To roll back a Docker project, push the commit you want (`rollback`
only switches static releases). Application logs are on the server:
`docker compose -p my-api logs`.

## When something is wrong

| Message | What to do |
|---|---|
| "Docker-проект не допущен политикой" (not admitted by policy) | no `/etc/sandbox/projects/<app>.conf` with `profile=compose` |
| `compose policy: …` | fix the named key; see the table above |
| "docker compose config failed" | compose file syntax or an unknown variable |
| "health_url должен вести на …" (health_url must point to …) | the check address may only go through Caddy on the project's domain |
| "приложение не ответило … за отведённое время" (no answer in time) | the service did not come up: `docker compose -p <app> logs` |
| the app cannot write to `./data` | userns-remap: use a named volume or give the directory to the shifted UID |
| the app cannot reach a database on the host | by design (firewall): keep the database in the project's compose file |
