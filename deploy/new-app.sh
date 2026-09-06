#!/usr/bin/env bash
# Создаёт новый sandbox-проект: bare git-репозиторий + подключённый deploy-хук.
# Использование: ./new-app.sh <app-name>
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <app-name>" >&2
    exit 1
fi

NAME="$1"
REPO="/srv/git/$NAME.git"

if [[ -d "$REPO" ]]; then
    echo "!! $REPO уже существует" >&2
    exit 1
fi

git init --bare "$REPO" >/dev/null
ln -s /srv/deploy/hook.sh "$REPO/hooks/post-receive"
chmod +x "$REPO/hooks/post-receive"

echo "✓ Создан sandbox-проект: $NAME"
echo ""
echo "Добавь remote локально:"
echo "  git remote add prod ssh://deploy@sandbox.example.com$REPO"
echo ""
echo "Деплой:"
echo "  git push prod main"
echo ""
echo "Если это Docker-проект с HTTP — добавь в docker-compose.yml сервиса лейблы:"
echo "  labels:"
echo "    caddy: $NAME.sandbox.example.com"
echo "    caddy.reverse_proxy: \"{{upstreams <внутренний_порт>}}\""
