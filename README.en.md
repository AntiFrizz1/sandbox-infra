[Русский](README.md) | **English**

# Sandbox infrastructure for a VPS

Git-push deploys for static sites, SPAs and Docker applications through one
shared post-receive hook and Caddy with automatic TLS (DNS-01, Timeweb).
Built for a single owner: only they deploy, and a visitor of a compromised
test project must not reach the server.

## Documentation

- [Installing on a VPS](docs/en/install.md) — preparing images, bootstrap,
  DNS, the client, updates and maintenance.
- [Deploying a static site](docs/en/deploy-static.md)
- [Deploying a Node project with a build step (Vite, React, SPA)](docs/en/deploy-node.md)
- [Deploying a Docker project (backend, database, bot)](docs/en/deploy-docker.md)
- In Russian only: [migrating a running VPS](docs/MIGRATION.md),
  [the detailed plan from the old layout](docs/MIGRATION-LEGACY.md),
  [security status](docs/SECURITY-REMEDIATION-STATUS.md),
  [apply and rollback runbook](docs/SECURITY-RUNBOOK.md),
  [audit](docs/SECURITY-AUDIT-2026-09-20.md),
  [remediation plan](docs/SECURITY-REMEDIATION-PLAN.md)

## Security remediation

This branch changes compatibility: Node projects are built only in an
isolated worker, and Docker projects run only under a root policy and after
their compose file is checked — without a policy a project does not deploy.
The public Caddy is separated from the controller that holds the Docker
socket; updating requires moving the Caddyfile into `config/` and keeping the
certificate volumes. This is a locally verified candidate; it has not been
applied to a live VPS yet. Do not use the old bulk update procedure without
the [runbook](docs/SECURITY-RUNBOOK.md).

## Quick start

On your machine: build the images and export archives with checksums.

```bash
docker build -t sandbox-caddy:candidate caddy/
docker build -t sandbox-worker:candidate worker/
scripts/scan-image.sh sandbox-caddy:candidate caddy      # recommended
scripts/scan-image.sh sandbox-worker:candidate worker
scripts/export-image.sh sandbox-caddy:candidate caddy.tar --artifact caddy
scripts/export-image.sh sandbox-worker:candidate worker.tar --artifact worker
```

On the VPS (Ubuntu 22.04/24.04, as root):

```bash
SANDBOX_CADDY_ARCHIVE=/root/caddy.tar SANDBOX_CADDY_ARCHIVE_SHA256=<sha256> ./bootstrap.sh
/srv/deploy/load-image.sh /root/worker.tar <sha256>
```

Then the domain and email in the Caddyfile, the Timeweb token, DNS records
and SSH keys — step by step in [docs/en/install.md](docs/en/install.md).
A project:

```bash
sandbox-deploy init myapp && sandbox-deploy push
```

## Project types

| Type | When | Needed on the server | Guide |
|---|---|---|---|
| `static` | ready HTML/CSS/JS | nothing | [deploy-static.md](docs/en/deploy-static.md) |
| `node` | a frontend with a build step | root policy `profile=worker` | [deploy-node.md](docs/en/deploy-node.md) |
| `docker` | backend, database, bot, SSR | root policy `profile=compose` | [deploy-docker.md](docs/en/deploy-docker.md) |

The type and publish directory are set by `.sandbox.conf` at the repository
root (examples in `examples/`); otherwise they are detected from files: a
compose file → `docker`, `package.json` → `node`, otherwise `static`.

```
type=static|node|docker   # detected automatically when not set
publish_dir=public        # what to publish; defaults: public/ (static), dist/ (node)
build_cmd=npm run build   # node only
spa=false                 # true — index.html fallback for SPA routes
health_url=               # docker: https://<app>.<domain>/… (checked through Caddy)
```

A project lives at `https://<app>.sandbox.<domain>`. Only the `main` branch
deploys.

## Repository layout

```
bootstrap.sh          — one-off installation on a fresh VPS
update-infra.sh       — updating an installed infrastructure
examples/             — .sandbox.conf for static, Vite, Docker and the old layout;
                        root policies worker-policy.conf and compose-policy.conf
tests/                — tests (bash tests/run.sh) and mandatory integration scripts
scripts/check-release.py — release gate over the image manifest and scans
scripts/scan-image.sh    — Trivy scan and Syft SBOM of an image into the release manifest
scripts/export-image.sh  — archive of a reviewed image to move to the VPS
docs/
  ru/, en/               — installation and deployment guides
  MIGRATION.md           — moving a deployed VPS to the new layout (Russian)
  MIGRATION-LEGACY.md    — detailed step-by-step plan from the old layout (Russian)
  SECURITY-*.md          — audit, plan, status and runbook (Russian)
caddy/
  Dockerfile           — Caddy built with xcaddy (docker-proxy + timeweb), pinned by digest
  docker-compose.yml   — public server and the controller with the Docker socket
  Caddyfile             — Caddy config (domain and email are placeholders)
  .env.example          — template for TIMEWEB_API_TOKEN
worker/
  Dockerfile, run.sh     — disposable Node build container (fetch / build)
deploy/
  hook.sh                — shared post-receive hook: detects the project type and deploys
  lib/common.sh          — name validation, path guards, private files, locks
  lib/project.sh         — project type, .sandbox.conf, publish directory
  lib/release.sh         — atomic release publication and rollback
  lib/caddy.sh           — per-project SPA rules and Caddy reload
  lib/runner.sh          — root policies and the two-phase worker
  lib/compose.sh         — running Docker projects under profile=compose
  lib/migration.sh       — safe migration of served sites with backup and quarantine
  lint-compose.py        — allowlist check of the compose model
  bounded-log.py         — size-limited deploy log
  new-app.sh             — create a new bare repository on the VPS
  redeploy-app.sh        — rebuild the current main without a new commit
  stop-app.sh            — stop a project temporarily
  rollback-app.sh        — roll back to a previous release without rebuilding
  status-app.sh          — project state, deploy outcome check
  list-apps.sh           — all projects and their state
  logs-app.sh            — deploy logs
  cleanup-app.sh         — clean up a project's finished logs
  repair-permissions.sh  — fix modes of private state
  remove-app.sh          — remove a project completely
  migrate.sh             — move the old layout to the new one
  load-image.sh          — load an image from an archive, verifying its SHA-256
  maintenance.sh         — daily cleanup and disk check (by timer)
  firewall.sh            — keep containers away from the host and private networks
  userns.sh              — enable userns-remap and migrate volumes
  harden-host.sh         — unattended upgrades and key-only SSH
  systemd/               — sandbox-maintenance.{service,timer}, sandbox-firewall.service
client/
  sandbox-deploy           — local interactive client (see below)
```

## Updating the infrastructure

`bootstrap.sh` is for the first installation only. A running VPS is updated
by a separate script that **does not overwrite settings**:

```bash
cd /path/to/sandbox-infra && git pull
sudo ./update-infra.sh --dry-run    # show what would change
sudo ./update-infra.sh
```

It carries the domain and email from the live `Caddyfile` into the new
template, shows a diff, backs up to `/root/sandbox-backups/`, runs
`caddy validate` and rolls back if the check fails. Scripts in `/srv/deploy`
are installed owned by root; the maintenance and firewall systemd units are
updated and enabled. `.env`, project state, releases and bare repositories
are not touched. The new Caddy `docker-compose.yml` is installed only after
the Caddyfile has been moved to `/srv/caddy/config/` per the runbook.
`update-infra` does not enable userns-remap or host hardening by itself: on
a running VPS that is done separately (`userns.sh`, `harden-host.sh`,
runbook). `--scripts-only` and `--caddy-only` update the parts separately.
New images go through `load-image.sh`, see
[installation](docs/en/install.md#updating).

## Releases and rollback

A static site is not published "over" the previous version but into a
separate directory tied to the commit:

```
/srv/sites/<app>/releases/<sha>/     build of a specific commit
/srv/sites/<app>/current -> releases/<sha>    relative symlink
```

`current` is switched atomically (`rename(2)`) and only after a successful
build and a check of its output. A failed build therefore does not break the
running site: it keeps serving the previous release. The five latest
successful releases are kept; the current one is never removed.

```bash
/srv/deploy/rollback-app.sh myapp           # to the previous release
/srv/deploy/rollback-app.sh myapp --list    # what is kept
/srv/deploy/rollback-app.sh myapp a1b2c3d   # to a specific release
```

Rollback only switches the link — nothing is rebuilt. Rebuilding the same
commit gets the ID `<sha>.<suffix>`; the previous directory is left
unchanged. `rollback --list` shows the full build IDs.

Locks live in `/srv/state/.locks/<app>.lock`, and the shared Caddy
configuration lock in `/srv/state/.locks/.caddy.lock`. These files are kept
when a project is removed, so waiting processes keep using the same lock.
When updating from an old version, wait for all operations to finish: the
old and new lock paths must not be used at the same time.

A project's state on the server is in `/srv/state/<app>/`:

```
config                 server-side config (when the repository has no .sandbox.conf)
env                    Docker project runtime secrets: copied into its .env and
                       the only source for compose interpolation
build-env              secrets given to the worker's build phase (Node)
deploys.tsv            history: time, branch, sha, outcome, duration
releases.tsv           order of successful releases
docker-active-sha      the commit running in a Docker project
compose.override.json  server-side limits and restrictions for compose
logs/<sha>.log         deploy log of a specific commit (up to 1 MiB)
```

All of these are private (directories 0700, files 0600).

## Stopping and removing a project

```bash
/srv/deploy/stop-app.sh myapp     # stop temporarily, data is kept
/srv/deploy/remove-app.sh myapp   # remove completely and irreversibly
```

`stop-app.sh` stops Docker containers (`docker compose -p <app> down`, by
project name, without reading the compose file) or removes the `current`
link — the releases stay, so the project comes back with a rollback, without
waiting for a rebuild. The bare repository is not touched. To run without a
new commit, use `sandbox-deploy redeploy myapp`: pushing an unchanged branch
again does not trigger the hook.

`remove-app.sh` removes everything: the bare repository, the working
checkout, the static site and (for Docker projects) containers, volumes and
locally built images. It asks for confirmation unless `--force`/`-y` is
given.

## Local client `client/sandbox-deploy`

An interactive bash script for the developer's machine — no manual SSH
login when creating a project.

What it does:
- For an existing project it takes the name from the `prod` remote, not
  from the folder name: the folder may have been renamed or cloned under
  another name.
- Works inside a git worktree, where `.git` is a file, not a directory.
- **Leaves the working tree alone.** It pushes only what is already
  committed and warns about uncommitted changes. To commit explicitly:
  `--commit-all "message"`.
- Does not rename the current branch. The push sends `HEAD` to
  `refs/heads/main`, so the local branch can have any name.
- **Checks that the deploy really succeeded.** A failed `post-receive` does
  not undo an accepted push, so a zero exit code from `git push` proves
  nothing. The client asks the server for the outcome of exactly this
  commit and exits with an error if it failed.
- Scripts must confirm operations with an explicit `-y` / `--yes`. The
  absence of a terminal does not by itself confirm removal or anything else.

Setup (no host hard-coded in the script, so it can live in a public
repository with your other scripts):

```bash
mkdir -p ~/.config/sandbox-deploy
echo 'SANDBOX_HOST=deploy@sandbox.example.com' > ~/.config/sandbox-deploy/config
```

Usage:

```bash
sandbox-deploy init [myapp]        # create the project on the VPS and set up the remote
sandbox-deploy push                # push and wait for the deploy outcome
sandbox-deploy push --commit-all "message"   # commit everything and push
sandbox-deploy status [myapp]      # active release and last deploy
sandbox-deploy list                # all projects on the VPS
sandbox-deploy logs [myapp] [sha|--list]
sandbox-deploy redeploy [myapp]    # rebuild the server's main, keeping the local index
sandbox-deploy rollback [myapp] [sha|--list]
sandbox-deploy stop [myapp]        # stop temporarily
sandbox-deploy remove [myapp]      # remove completely and irreversibly
```

The project name is optional — it comes from the `prod` remote. `-y`/`--yes`
turns off all questions. The client's own messages are in Russian.

`status` shows the active release and the last deploy attempt separately.
`--check` compares a SHA with the active version: a historical success after
a stop or a rollback returns `inactive`. These are different things: a
failed static deploy does not change what is served, and `status` says
plainly that the site runs on the previous commit.

## Serving and SPAs

`spa=true` turns on an `index.html` fallback, but only for what looks like
an application route. Existing files are served as they are, and a missing
`.js`, `.css`, font or image honestly returns 404 — otherwise the browser
would get HTML instead of a script and fail with an obscure parse error.

The rules are generated by the deploy hook into
`/srv/caddy/spa.d/<app>.caddy` and imported inside the Caddyfile's wildcard
block. A separate site block per project is avoided on purpose: it would
make Caddy issue a certificate per subdomain instead of one wildcard.

Before applying, the configuration is checked with `caddy validate`. Then
the controller restarts: it assembles the configuration together with the
Docker label routes and hands it to the public server over a separate
control network. A shared lock serialises Caddy changes. In the old layout
the container is recreated so the bind-mount inode is refreshed, which
causes a short interruption. A plain `caddy reload` of the base Caddyfile
must not be used: it lacks the generated Docker routes. If the check fails,
the rules are rolled back and Caddy is not reloaded. If Caddy is not running
at the moment, the rules stay on disk and are picked up on the next start.

**Only** `publish_dir` is published, not the whole repository. This protects
against accidentally serving sources and server files. Even inside it, dot
files (except `.well-known`), `.env*`, `*.env`, keys (`*.pem`, `*.key`,
`id_rsa*`, `id_ed25519*`), `.sandbox.conf` and a top-level `node_modules` are
not published. Independently, Caddy answers 403 for dot paths, `.env` and
keys, nested and URL-encoded ones included. Symlinks leading outside the
published directory are refused and fail the deploy.

## Protecting the host from a compromised project

A test project may turn out to be vulnerable: a visitor gets code execution
in its container. From there they are held back by:

- **the firewall** (`deploy/firewall.sh`, unit `sandbox-firewall.service`):
  containers cannot reach the host itself (SSH or any of its services),
  private networks (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`) or cloud
  metadata (`169.254/16`). The internet is open, and Caddy → application
  traffic is unaffected. An application that needs a database on the host or
  in the provider's private network will not work this way — keep the
  database in the project's compose file;
- **userns-remap** (`deploy/userns.sh`, bootstrap enables it on a fresh
  Docker): root inside a project container is an unprivileged host UID, so
  even a container escape through a kernel bug does not give root on the
  VPS. A directory the container writes to through a bind mount must belong
  to the shifted UID; named volumes are easier. Moving a running VPS: see
  `docs/SECURITY-RUNBOOK.md`;
- reduced capabilities and `no-new-privileges` from the server-side
  override (see [deploy-docker.md](docs/en/deploy-docker.md));
- **host hardening** (`deploy/harden-host.sh`, run by bootstrap):
  `unattended-upgrades` installs security updates and reboots at night, at
  04:30, when a new kernel needs it (`SANDBOX_AUTO_REBOOT=false` disables the
  reboot); SSH by key only, root included. Passwords are turned off only if
  root already has a key in `authorized_keys`; otherwise the step is skipped
  with a warning, so you cannot be locked out. On an already installed VPS
  run `sudo /srv/deploy/harden-host.sh` by hand.

## Not implemented yet (deferred)

- Non-HTTP TCP protocols (needs `caddy-l4`; projects may not publish ports
  under the compose policy).
- Processes without Docker through systemd units.
- Isolating projects from each other inside `sandbox_net`.

## Tests

```bash
bash tests/run.sh
```

The tests need bash, git, rsync, coreutils, flock, python3 with PyYAML and
docker compose. They work in temporary directories and never touch the real
`/srv`. ShellCheck runs automatically, or through `koalaman/shellcheck` in
docker when it is not installed.

Docker tests start a real Caddy and check HTTP answers, permissions after a
root migration, and the compose policy on a real container. The firewall,
host hardening and userns-remap are tested in throwaway containers
(privileged and Docker-in-Docker among them): this machine's iptables, sshd
and Docker settings are not changed and its build cache is not pruned.
Without docker these checks are skipped. The first run downloads Debian,
Caddy and `docker:28-dind` images.

A release also requires `tests/security-integration.sh`,
`tests/proxy-isolation.sh` and `tests/worker-isolation.sh`; missing Docker
or images count as a failure of these checks.

## Resource limits

One deploy log is capped at 1 MiB. A deploy does not start with less than
`SANDBOX_MIN_FREE_MB` (1024) free. The worker's build tree is bounded by the
policy's `output_mb`: the dispatcher polls the size and the free space and
kills the container when exceeded. This is polling, not a filesystem quota:
between checks (5 s) a build can write more.

`sandbox-maintenance.timer` (installed by bootstrap and update-infra) runs
`maintenance.sh` daily: finished logs (20 files/20 MiB, 200 history rows),
leftovers of interrupted deploys — only when the project is not busy,
`git gc --auto`, Docker build cache and dangling images older than a week,
migration backups beyond the newest three and older than 30 days. Published
releases, volumes and application data are never touched. With less than
`SANDBOX_ALERT_FREE_MB` (2048) free the unit exits with status 2, visible in
`systemctl --failed` and the journal. `maintenance.sh --dry-run` shows the
plan.
