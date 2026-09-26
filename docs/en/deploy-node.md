[Русский](../ru/deploy-node.md) | **English**

# Deploying a Node project with a build step (Vite, React, Vue, SPA)

A frontend that has to be built: `npm ci && npm run build` produces static
files. The build runs in a disposable isolated container (the worker), and
the result is published the same way as a [static site](deploy-static.md).

Server-side Node (Express, Next.js in server mode, an API) does not work
this way: nothing keeps running after the build. Use a
[Docker project](deploy-docker.md) for that.

## 1. Policy on the server

Build code is untrusted by definition (dependencies from npm), so what runs
and how is decided by a root policy, not by the repository. Usually there is
nothing to do: the shared policy `/etc/sandbox/defaults/worker.conf` applies.
bootstrap and `update-infra.sh` install it, and `load-image.sh … --worker`
writes the worker image ID into it ([installation](install.md#3-finish-by-hand)).

Different limits for one project go into a separate file, which wins:

```bash
sudo install -m 644 -o root -g root \
    /etc/sandbox/defaults/worker.conf /etc/sandbox/projects/my-app.conf
sudo nano /etc/sandbox/projects/my-app.conf
```

| Key | Default | Meaning |
|---|---|---|
| `profile` | — | always `worker` |
| `image` | — | a `sha256:…` ID or `<registry>/<image>@sha256:…`; tags are refused |
| `timeout_seconds` | 300 | limit for each of the two phases |
| `memory_mb` | 512 | container memory (no swap) |
| `pids` | 128 | process limit |
| `cpus` | 1 | CPU |
| `output_mb` | 2048 | limit for the build tree (sources, `node_modules`, output) |
| `fetch_network` | `sandbox_build` | network for downloading dependencies; only `none` or a network labelled `sandbox.role=build` |
| `npm_registry` | `https://registry.npmjs.org/` | npm registry; overrides the project's `.npmrc` |

The file and every directory above it must be owned by root and not
writable by group or others. A project file with wrong permissions is an
error, not a reason to silently use the shared policy. Without a policy the
build does not run, and it never runs on the host.

## 2. Repository

```
my-app/
├── package.json         ← with a "build" script
├── package-lock.json    ← recommended: npm ci, reproducible
├── src/ …
└── .sandbox.conf
```

`.sandbox.conf` (example: `examples/vite.sandbox.conf`):

```
type=node
build_cmd=npm run build
publish_dir=dist        # Create React App: build
spa=true                # client-side routing
```

Without `.sandbox.conf`, a project with `package.json` is a Node project
with `build_cmd=npm run build` and `publish_dir=dist`.

## 3. Deploy

```bash
sandbox-deploy init my-app
sandbox-deploy push
```

or `ssh deploy@<VPS> /srv/deploy/new-app.sh my-app`, `git remote add prod …`,
`git push prod main` — as for [static sites](deploy-static.md#first-deploy).

## How the build runs

Two disposable containers sharing a `/work` directory:

1. **fetch** — network from `fetch_network`, sources read-only. Copies them
   into `/work` and runs `npm ci --ignore-scripts` (or
   `npm install --ignore-scripts` without a lock file). npm only downloads
   and unpacks packages: neither the project's code nor dependency scripts
   run while there is network.
2. **build** — no network and no access to the sources. `npm rebuild`
   (dependency install scripts, native modules built by node-gyp against the
   image's headers), then the project's `preinstall`, `install`,
   `postinstall`, `prepare` scripts and `build_cmd`.

Both containers: read-only root, no capabilities, `no-new-privileges`, the
deploy user's UID, no access to `/srv`, SSH keys or the Docker API, limits
from the policy. If the build tree exceeds `output_mb` or less than 1 GB of
disk is left, the container is stopped. `publish_dir` is then published as a
new release with the same exclusions as static sites (dot files, `.env`,
keys, top-level `node_modules`).

## Build secrets

Variables needed during the build (say, a public API key for the frontend)
go into `/srv/state/<app>/build-env` (`.env` format, mode `0600`, owned by
deploy). Only the build phase sees the file; it is copied to `/work/.env`,
which Vite and similar tools read by themselves. Remember: anything that ends
up in the built frontend is visible to every visitor, and dependency code
sees the whole file. Node builds do not get the runtime secrets
(`/srv/state/<app>/env`).

## Limitations

- **Git dependencies do not work**: the image has no git.
- **Packages that download something in postinstall** (Puppeteer with
  Chromium, Cypress, Electron) fail: the build phase has no network. Turn the
  download off through the package's own settings, or keep such packages out
  of frontend dependencies.
- **A build that goes to the network** (fetching fonts, calling an API during
  `build`) will not work either.
- **A private registry** is set in the policy (`npm_registry`). A registry in
  the provider's private network is blocked by the firewall.

## Management

Same commands as for static sites: `status`, `logs`, `rollback`,
`redeploy`, `stop`, `remove` — see
[deploy-static.md](deploy-static.md#management). The build log of a specific
commit: `sandbox-deploy logs my-app <sha>` (up to 1 MiB).

## When something is wrong

| Message | What to do |
|---|---|
| "root-owned execution policy required" | neither a shared nor an own policy — `sudo ./update-infra.sh` |
| "… must be a root-owned file …" | wrong owner or permissions on a policy file |
| "image in … must be …" | the worker image is not loaded (`load-image.sh … --worker`) or `image=` holds a tag |
| "fetch_network must be none or a network labelled …" | the network does not exist or lacks the `sandbox.role=build` label |
| "worker fetch failed" | see the log: usually the lock file does not match `package.json`, or there is no network (`fetch_network=none`) |
| "worker build failed" | the project's build failed, or a package tried to download something without network |
| "worker … stopped: output …" | `output_mb` exceeded or the disk is running out |
| "failed/timeout (137)" | out of memory (`memory_mb`) |
| "каталог публикации 'dist' непригоден" (publish directory unusable) | the build writes somewhere other than `dist` — fix `publish_dir` |
