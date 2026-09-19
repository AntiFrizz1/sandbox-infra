#!/usr/bin/env bash
# Откатывает статический проект на предыдущий успешный релиз без пересборки.
# Использование: ./rollback-app.sh <app-name> [<sha>]
#                ./rollback-app.sh <app-name> --list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$SCRIPT_DIR/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <app-name> [<sha>|--list]" >&2
    exit 1
fi

NAME="$1"
require_valid_app_name "$NAME"
WANT="${2-}"
lock_app "$NAME"
[[ -z $WANT || $WANT == --list || $WANT =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "недопустимый релиз"

SITE="$(app_site_dir "$NAME")"
[[ -d "$SITE/releases" ]] || die "[$NAME] сохранённых релизов нет — откатываться некуда"

CURRENT="$(current_release_id "$NAME" 2>/dev/null || true)"

if [[ "$WANT" == "--list" ]]; then
    echo "Сохранённые релизы проекта '$NAME' (новые сверху):"
    while IFS= read -r sha; do
        [[ -n "$sha" ]] || continue
        [[ -d "$(release_dir "$NAME" "$sha")" ]] || continue
        if [[ "$sha" == "$CURRENT" ]]; then
            printf '  %s  <- текущий\n' "$sha"
        else
            printf '  %s\n' "$sha"
        fi
    done < <(release_history "$NAME")
    exit 0
fi

# Полный sha принимается как есть; короткий — разворачивается по журналу.
if [[ -n "$WANT" && ! -d "$(release_dir "$NAME" "$WANT")" ]]; then
    MATCH=""
    while IFS= read -r sha; do
        [[ "$sha" == "$WANT"* ]] || continue
        [[ -d "$(release_dir "$NAME" "$sha")" ]] || continue
        [[ -n "$MATCH" ]] && die "[$NAME] префикс '$WANT' подходит нескольким релизам"
        MATCH="$sha"
    done < <(release_history "$NAME")
    [[ -n "$MATCH" ]] || die "[$NAME] релиз '$WANT' не найден среди сохранённых"
    WANT="$MATCH"
fi

TARGET=$(rollback_release "$NAME" "$WANT") || die "[$NAME] откат не выполнен"

log "[$NAME] откат выполнен: ${CURRENT:0:12} → ${TARGET:0:12}"
echo "   Пересборки не было — переключена только ссылка current."
