#!/usr/bin/env bash
# Печатает лог деплоя. Без аргумента — лог последней попытки, включая
# провалившуюся: именно её обычно и хотят посмотреть.
# Использование: ./logs-app.sh <app-name> [<sha>|--list]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <app-name> [<sha>|--list]" >&2
    exit 1
fi

NAME="$1"
require_valid_app_name "$NAME"
WANT="${2-}"

STATEDIR="$(app_state_dir "$NAME")"
LOGDIR="$STATEDIR/logs"
DEPLOYS="$STATEDIR/deploys.tsv"

[[ -d "$LOGDIR" ]] || die "[$NAME] логов деплоя нет"

if [[ "$WANT" == "--list" ]]; then
    [[ -f "$DEPLOYS" ]] || die "[$NAME] история деплоев пуста"
    printf '%-22s %-14s %-8s %s\n' ВРЕМЯ КОММИТ ИСХОД ДЛИТЕЛЬНОСТЬ
    while IFS=$'\t' read -r ts _ref sha outcome dur; do
        printf '%-22s %-14s %-8s %s\n' "$ts" "${sha:0:12}" "$outcome" "$dur"
    done < "$DEPLOYS"
    exit 0
fi

if [[ -z "$WANT" ]]; then
    [[ -f "$DEPLOYS" ]] || die "[$NAME] история деплоев пуста"
    WANT=$(tail -1 "$DEPLOYS" | cut -f3)
fi

# Короткий sha разворачивается по имеющимся логам.
LOG="$LOGDIR/$WANT.log"
if [[ ! -f "$LOG" ]]; then
    shopt -s nullglob
    matches=("$LOGDIR/$WANT"*.log)
    case ${#matches[@]} in
        0) die "[$NAME] лог для '$WANT' не найден" ;;
        1) LOG="${matches[0]}" ;;
        *) die "[$NAME] префикс '$WANT' подходит нескольким логам" ;;
    esac
fi

echo "=== $LOG ==="
cat "$LOG"
