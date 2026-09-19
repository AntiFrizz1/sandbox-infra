#!/usr/bin/env bash
# Создаёт новый sandbox-проект: bare git-репозиторий + подключённый deploy-хук.
# Использование: ./new-app.sh <app-name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <app-name>" >&2
    exit 1
fi

NAME="$1"
require_valid_app_name "$NAME"

REPO="$(app_repo_dir "$NAME")"

if [[ -e "$REPO" ]]; then
    die "$REPO уже существует"
fi

mkdir -p "$SANDBOX_GIT_ROOT"
git init --bare "$REPO" >/dev/null

# Симлинк на общий хук. chmod здесь не нужен и был бы вреден: он следует
# по ссылке и менял бы права самого /srv/deploy/hook.sh, а не ссылки.
ln -s "$SCRIPT_DIR/hook.sh" "$REPO/hooks/post-receive"

log "Создан sandbox-проект: $NAME"
cat <<EOF

Добавь remote локально:
  git remote add prod ssh://deploy@${SANDBOX_SSH_HOST}${REPO}

Деплой:
  git push prod main

Если это Docker-проект с HTTP — добавь в docker-compose.yml сервиса лейблы:
  labels:
    caddy: ${NAME}.${SANDBOX_DOMAIN}
    caddy.reverse_proxy: "{{upstreams <внутренний_порт>}}"
EOF
