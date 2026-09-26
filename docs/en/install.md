[Русский](../ru/install.md) | **English**

# Installing on a VPS

How to install sandbox-infra on a fresh VPS: from preparing the images on
your own machine to the first project. Moving an already running server to
this version is covered separately in
[SECURITY-RUNBOOK.md](../SECURITY-RUNBOOK.md) and
[MIGRATION.md](../MIGRATION.md) (both in Russian).

## How it fits together

```
 your machine                                VPS
 ────────────                                ───
 git push prod main ──ssh──▶ /srv/git/<app>.git
                                  │ post-receive → /srv/deploy/hook.sh
                                  ▼
                 static ─────▶ /srv/sites/<app>/releases/<sha>, current → …
                 node   ─────▶ worker (fetch with network → build without) → releases
                 docker ─────▶ docker compose -p <app> (under a root policy)
                                  │
 browser ──https──▶ Caddy (server) ◀── controller (reads Docker labels)
                    https://<app>.sandbox.<domain>
```

- Static sites and built SPAs are served by Caddy from
  `/srv/sites/<app>/current` under a single wildcard certificate
  `*.sandbox.<domain>` (DNS-01 through Timeweb).
- Docker projects are published through `caddy:` labels in their own compose
  file; Caddy gets a separate certificate for them over HTTP-01.
- Only the server owner deploys. The protection is aimed at a visitor of a
  compromised test project not reaching the server (see
  "Protecting the host" in the [README](../../README.en.md)).

## What you need

**VPS**
- Ubuntu 22.04 or 24.04 (bootstrap installs `docker.io` and
  `docker-compose-v2` from the Ubuntu archive; on Debian install Docker and
  Compose from Docker's signed repository first).
- SSH access as root, ideally with a key from the start.
- Memory for Caddy, the build worker (up to 512 MB by default) and your
  Docker projects. 2 GB or more is reasonable for a couple of test projects.

**Domain and DNS at Timeweb**
- A domain whose DNS zone is hosted by Timeweb. Below it is `example.com`,
  and projects live at `<app>.sandbox.example.com`.
- A Timeweb Cloud API token (panel → API keys) allowed to change DNS
  records: Caddy creates the `_acme-challenge` TXT record for the wildcard
  certificate.

**Your machine**
- Docker with Compose, git, python3, bash.
- A clone of this repository.

## 1. Prepare the images on your machine

The Caddy and worker images are not built on the VPS: you build them once
locally and move them over as archives whose checksum the server verifies.

```bash
git clone <URL-of-this-repository> sandbox-infra && cd sandbox-infra
docker build -t sandbox-caddy:candidate caddy/
docker build -t sandbox-worker:candidate worker/
```

- **Caddy** — a Caddy build with the `caddy-docker-proxy` plugin (routes
  from Docker labels) and `caddy-dns/timeweb` (DNS-01). Versions and base
  images are pinned in `caddy/Dockerfile`.
- **worker** — Node 22 with a compiler for native modules; Node projects are
  built in it.

### Scan (recommended)

```bash
scripts/scan-image.sh sandbox-caddy:candidate caddy
scripts/scan-image.sh sandbox-worker:candidate worker
python3 scripts/check-release.py
```

`scan-image.sh` runs Trivy and Syft from digest-pinned images and records
the scan, the SBOM and the finding counts in
`docs/security-remediation/release-manifest.json`. `check-release.py` shows
what blocks a release: HIGH/CRITICAL findings without a fix have to be fixed
(update the base image) or covered by an exception in
`docs/security-remediation/exceptions.json`, with a reason, an owner and an
expiry of at most 90 days. A finding that has a fixed version cannot be
excepted. You set the approval (`approved`) yourself.

### Export

```bash
scripts/export-image.sh sandbox-caddy:candidate caddy.tar --artifact caddy
scripts/export-image.sh sandbox-worker:candidate worker.tar --artifact worker
```

Each command prints the SHA-256 of the archive — keep both. With
`--artifact` the script refuses an image that is not the scanned one and
records the archive in the manifest. Without a scan, run it without
`--artifact`.

## 2. Install on the VPS

Copy only the archives from your machine and clone the repository on the
server, so that service directories such as `.git` with local branches,
`.claude/` or `.remember/` stay behind:

```bash
scp caddy.tar worker.tar root@<IP>:/root/
ssh root@<IP>
git clone https://github.com/AntiFrizz1/sandbox-infra.git /root/sandbox-infra
cd /root/sandbox-infra
SANDBOX_CADDY_ARCHIVE=/root/caddy.tar \
SANDBOX_CADDY_ARCHIVE_SHA256=<sha256 of caddy.tar> \
SANDBOX_WORKER_ARCHIVE=/root/worker.tar \
SANDBOX_WORKER_ARCHIVE_SHA256=<sha256 of worker.tar> \
    ./bootstrap.sh
```

The sums are the `sha256:` lines printed by `export-image.sh` (or
`sha256sum *.tar` on your machine). The worker archive is optional here and
can be loaded later (step 3.6).

If the Caddy image is in a registry, use
`SANDBOX_CADDY_IMAGE='<registry>/<image>@sha256:<digest>'` instead of the two
archive variables.

What bootstrap does, in order:

1. Creates the `deploy` user — `git push` and deploys run as it.
2. Installs Docker, Compose, rsync, git, python3 with PyYAML, curl, util-linux.
3. Creates `/srv/{git,apps,sites,state,deploy,caddy}` and the default root
   policies `/etc/sandbox/defaults/worker.conf` and `compose.conf`, which
   Node builds and Docker projects run under.
4. On a Docker with no containers or volumes, enables **userns-remap**: root
   inside project containers becomes an unprivileged host UID. If Docker
   already has containers or volumes, the step is skipped — follow the
   runbook to migrate.
5. Creates the networks `sandbox_net` (Caddy ↔ projects) and `sandbox_build`
   (npm downloads by the worker).
6. Installs the scripts into `/srv/deploy` owned by root and enables
   `sandbox-maintenance.timer` (daily cleanup) and
   `sandbox-firewall.service` (containers cannot reach the host or private
   networks).
7. Creates `/srv/sandbox.conf`, `/srv/caddy/config/Caddyfile`,
   `/srv/caddy/docker-compose.yml` and `/srv/caddy/.env` (`root:deploy 0640`).
8. Verifies the SHA-256 of the Caddy archive, loads the image and writes
   its ID into `/srv/caddy/.env`. With a worker archive it does the same and
   writes the worker ID into the default policy. Starts Caddy.
9. Turns on unattended security upgrades and — if root already has a key in
   `/root/.ssh/authorized_keys` — disables password login.

Optional variables:

| Variable | Default | Effect |
|---|---|---|
| `SANDBOX_USERNS_REMAP` | `true` | `false` — do not enable userns-remap |
| `SANDBOX_AUTO_REBOOT` | `true` | `false` — do not reboot after a kernel update |
| `SANDBOX_REBOOT_TIME` | `04:30` | time of that reboot |
| `SANDBOX_SSH_HARDENING` | `true` | `false` — leave SSH settings alone |

## 3. Finish by hand

1. **Domain and email.** In `/srv/caddy/config/Caddyfile` replace the domain
   in three places: `*.sandbox.example.com`, the bare `sandbox.example.com`
   and the regular expression `\.sandbox\.example\.com$` (dots are escaped
   there: `\.sandbox\.your-domain\.com$`). Replace `you@example.com` with
   your email for Let's Encrypt. In `/srv/sandbox.conf` set
   `SANDBOX_DOMAIN=sandbox.<your domain>` and `SANDBOX_SSH_HOST` — the address
   you use to SSH into the server.
2. **Token.** Put `TIMEWEB_API_TOKEN=…` into `/srv/caddy/.env`. Leave the
   `SANDBOX_CADDY_IMAGE` line alone — bootstrap wrote it.
3. **DNS.** In the `example.com` zone at Timeweb add two A records pointing
   to the VPS:
   ```
   *.sandbox   A   <IP>
   sandbox     A   <IP>     (separately: the wildcard does not cover sandbox itself)
   ```
4. **Restart Caddy:**
   ```bash
   cd /srv/caddy && docker compose up -d --force-recreate
   ```
5. **SSH keys.** Put your public key into `/home/deploy/.ssh/authorized_keys`
   (pushes and the client use `deploy`). If bootstrap said root has no key,
   add one to `/root/.ssh/authorized_keys` as well and run
   `/srv/deploy/harden-host.sh` — it will turn off password login.
6. **Worker** — only if you did not pass it to bootstrap:
   ```bash
   /srv/deploy/load-image.sh /root/worker.tar <sha256 of worker.tar> --worker
   ```
   `--worker` writes the image ID into `/etc/sandbox/defaults/worker.conf`.
   From then on Node and Docker projects deploy without any root steps.

## 4. Check

```bash
curl -s https://sandbox.example.com           # "Sandbox root — see project subdomains"
curl -s https://nothing.sandbox.example.com   # "Unknown sandbox project" (404)
systemctl list-timers sandbox-maintenance.timer
systemctl status sandbox-firewall.service
docker run --rm busybox cat /proc/self/uid_map   # not "0 0 …" when remap is on
```

The first request to `*.sandbox` can take up to a minute while Caddy obtains
the wildcard certificate. Issuance errors show up in `docker compose logs caddy`
(in `/srv/caddy`).

## 5. Set up the client on your machine

`client/sandbox-deploy` wraps the SSH commands: it creates a project, pushes
and checks that the deploy really succeeded.

```bash
mkdir -p ~/.config/sandbox-deploy
echo 'SANDBOX_HOST=deploy@<VPS address>' > ~/.config/sandbox-deploy/config
cp client/sandbox-deploy ~/.local/bin/    # or any directory on PATH
```

Then, by project type: [static](deploy-static.md),
[Node/SPA](deploy-node.md), [Docker](deploy-docker.md).

## Updating

**Scripts and configuration.** On the VPS, in the repository clone:

```bash
git pull
sudo ./update-infra.sh --dry-run
sudo ./update-infra.sh
```

`update-infra.sh` installs the new scripts into `/srv/deploy`, updates the
systemd units, carries the domain and email from the live Caddyfile into the
new template, shows a diff, backs up to `/root/sandbox-backups/` and rolls
back if `caddy validate` fails. `.env`, projects and releases are left
alone. It does not turn on userns-remap or host hardening by itself.

**Images.** Build, scan and export a new image as in step 1, copy the
archive over and load it:

```bash
sudo /srv/deploy/load-image.sh caddy.tar <sha256> --caddy   # writes the ID into /srv/caddy/.env
cd /srv/caddy && docker compose up -d
sudo /srv/deploy/load-image.sh worker.tar <sha256> --worker # the ID goes into the default policy
```

Review the images monthly: exceptions in `exceptions.json` are granted for
30 days.

## Maintenance

- `sandbox-maintenance.timer` runs `/srv/deploy/maintenance.sh` daily: it
  trims finished deploy logs, removes leftovers of interrupted deploys, runs
  `git gc --auto`, prunes week-old Docker build cache and old migration
  backups. With less than 2 GB free the unit fails — visible in
  `systemctl --failed`. To see the plan:
  `sudo /srv/deploy/maintenance.sh --dry-run`.
- A deploy does not start with less than 1 GB free (`SANDBOX_MIN_FREE_MB`).
- The firewall is re-applied whenever Docker starts; by hand —
  `sudo /srv/deploy/firewall.sh`.
- `sudo /srv/deploy/repair-permissions.sh` fixes the modes of private state
  (has `--dry-run`).

## Troubleshooting

| Symptom | What to check |
|---|---|
| bootstrap: "SHA-256 архива не совпадает" (archive checksum mismatch) | the archive was damaged in transit or the sum belongs to another file — rerun `sha256sum` locally and on the VPS |
| no certificate for `*.sandbox` | the Timeweb token, its DNS rights, the `*.sandbox` record; `docker compose logs caddy` |
| `https://sandbox.<domain>` does not open | the separate `sandbox` A record, ports 80/443 in the provider's firewall |
| push succeeds but "ДЕПЛОЙ ПРОВАЛЕН" (deploy failed) | `sandbox-deploy logs <app>`: the full build log of that commit |
| "деплой отложен: на диске мало места" (low disk space) | `df -h`, `sudo /srv/deploy/maintenance.sh` |
| Node: "root-owned execution policy required" | no `/etc/sandbox/defaults/worker.conf` — `sudo ./update-infra.sh` |
| Node: "image in … must be …" | the worker image is not loaded — `load-image.sh … --worker` |
| Docker: "не допущен политикой" (not admitted by policy) | no `/etc/sandbox/defaults/compose.conf` — `sudo ./update-infra.sh` |

Server-side messages are in Russian; the English gloss is given in brackets.
