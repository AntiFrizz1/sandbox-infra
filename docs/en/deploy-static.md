[Русский](../ru/deploy-static.md) | **English**

# Deploying a static site

HTML, CSS, JS and images with no build step. No server-side policy is
needed: the hook copies the site directory into a new release and Caddy
serves it at `https://<app>.sandbox.<domain>`.

## Repository layout

```
my-site/
├── public/            ← only this is published
│   ├── index.html
│   ├── style.css
│   └── img/logo.png
├── .sandbox.conf      ← optional
└── README.md          ← not published
```

`.sandbox.conf` (example: `examples/static.sandbox.conf`):

```
type=static
publish_dir=public
spa=false
```

Without `.sandbox.conf`, and with no `package.json`, compose file or
`Dockerfile` at the root, the project is static with `publish_dir=public`.

## Project name

1–63 characters: lowercase Latin letters, digits and hyphens, with no hyphen
first or last. The name becomes the subdomain:
`my-site` → `https://my-site.sandbox.<domain>`.

## First deploy

With the client (see [installation](install.md#5-set-up-the-client-on-your-machine)):

```bash
cd my-site
git init && git add -A && git commit -m "first"
sandbox-deploy init my-site     # creates the repository on the VPS and the prod remote
sandbox-deploy push             # pushes and waits for the deploy outcome
```

Without the client:

```bash
ssh deploy@<VPS> /srv/deploy/new-app.sh my-site
git remote add prod ssh://deploy@<VPS>/srv/git/my-site.git
git push prod main
```

Only the `main` branch deploys. The client pushes `HEAD` to `main`, so your
local branch can have any name; with a plain `git push` push to `main`. If
the build fails, `git push` still reports success — the hook cannot reject
an accepted push. The line "✗ ДЕПЛОЙ ПРОВАЛЕН" (deploy failed) in the output
says so, and `sandbox-deploy push` exits with an error.

## What happens on push

1. The hook takes exactly the pushed commit (`git archive`) into a clean
   directory, so nothing from earlier builds leaks into the new one.
2. It copies `publish_dir` into `/srv/sites/<app>/releases/<sha>/` without:
   - dot files and directories (except `.well-known`),
   - `.env`, `.env.*`, `*.env`, `.sandbox.conf`,
   - keys: `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`,
   - a top-level `node_modules`.
   A symlink pointing outside `publish_dir` stops the deploy.
3. It switches `current` to the new release atomically. If anything failed
   earlier, the site keeps serving the previous version.

Caddy additionally answers 403 for dot paths, `.env` and keys — even if such
a file somehow ends up in a release.

## SPA without a build

If the site is a single-page app with client-side routing (a direct visit to
`/about` must return `index.html`), set `spa=true`. The fallback applies only
to paths that look like routes: existing files are served as they are, and a
missing `.js`, `.css`, font or image honestly returns 404.

## Site at the repository root

If the files are at the root, you need an explicit `publish_dir=.`
(`examples/legacy-root.sandbox.conf`). Secrets and dot files are still not
published, but the sources and everything else are. Better move the site
into `public/`.

## Management

```bash
sandbox-deploy status [my-site]          # active release and last deploy
sandbox-deploy logs [my-site] [sha|--list]
sandbox-deploy rollback [my-site]        # to the previous release, no rebuild
sandbox-deploy rollback [my-site] --list # saved releases
sandbox-deploy redeploy [my-site]        # rebuild main without a new commit
sandbox-deploy stop [my-site]            # stop serving, releases are kept
sandbox-deploy remove [my-site]          # delete everything, irreversibly
```

The name is optional — it comes from the `prod` remote. `-y` turns off the
questions. The five latest successful releases are kept; the current one is
never removed. After `stop`, `rollback` brings the project back.

On the server the same is available as `/srv/deploy/*-app.sh`, run as
`deploy`.

## When something is wrong

| Symptom | Cause |
|---|---|
| "каталог публикации 'public' непригоден" (publish directory unusable) | the commit has no `public/` — check `git ls-files public` |
| empty 404 on every path | the project has never deployed successfully or is stopped (`status`) |
| 404 "Unknown sandbox project" | the name in the address does not match the project name rule |
| nested path returns 404 | an SPA needs `spa=true` |
| a file in the repository is not served | it matches the exclusions (dot file, `.env`, key) |
