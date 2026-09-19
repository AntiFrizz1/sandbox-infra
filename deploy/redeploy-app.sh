#!/usr/bin/env bash
# Пересобирает текущую серверную ветку без изменения истории Git клиента.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
[[ $# -eq 1 ]] || die "Usage: $0 <app-name>"
NAME=$1
require_valid_app_name "$NAME"
REPO=$(app_repo_dir "$NAME")
SHA=$(git --git-dir="$REPO" rev-parse --verify "refs/heads/${SANDBOX_DEPLOY_BRANCH:-main}^{commit}")
cd "$REPO"
printf '%s %s refs/heads/%s\n' "$SHA" "$SHA" "${SANDBOX_DEPLOY_BRANCH:-main}" | "$SCRIPT_DIR/hook.sh"
"$SCRIPT_DIR/status-app.sh" "$NAME" --check "$SHA"
