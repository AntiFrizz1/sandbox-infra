#!/usr/bin/env bash
# Показывает состояние проекта: активный релиз, последний деплой и его исход.
#
# Активный релиз и последняя попытка деплоя — разные вещи: провалившийся
# деплой не меняет то, что отдаётся, поэтому они показываются раздельно.
#
# Использование: ./status-app.sh <app-name>
#                ./status-app.sh <app-name> --check <sha>   (код возврата)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$SCRIPT_DIR/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <app-name> [--check <sha>]" >&2
    exit 1
fi

NAME="$1"; shift
require_valid_app_name "$NAME"

CHECK_SHA=""
if [[ "${1-}" == "--check" ]]; then
    CHECK_SHA="${2-}"
    [[ -n "$CHECK_SHA" ]] || die "--check требует sha"
fi

REPO="$(app_repo_dir  "$NAME")"
STATEDIR="$(app_state_dir "$NAME")"
DEPLOYS="$STATEDIR/deploys.tsv"

[[ -d "$REPO" ]] || die "проект '$NAME' не найден"
lock_app "$NAME"
[[ -d "$REPO" ]] || die "проект '$NAME' удалён"

CURRENT="$(current_release_sha "$NAME" 2>/dev/null || true)"
if [[ -f "$STATEDIR/docker-active-sha" ]]; then
    CURRENT=$(cat "$STATEDIR/docker-active-sha")
fi

# last_record_for <sha> — строка из deploys.tsv для коммита, последняя попытка
last_record_for() {
    [[ -f "$DEPLOYS" ]] || return 1
    local line=""
    while IFS= read -r l; do
        [[ "$(cut -f3 <<<"$l")" == "$1" ]] && line="$l"
    done < "$DEPLOYS"
    [[ -n "$line" ]] || return 1
    printf '%s\n' "$line"
}

# --check: молча возвращает код — 0, если этот коммит развёрнут успешно.
if [[ -n "$CHECK_SHA" ]]; then
    record=$(last_record_for "$CHECK_SHA") || {
        echo "no-record"
        exit 2
    }
    outcome=$(cut -f4 <<<"$record")
    if [[ "$outcome" == ok && "$CURRENT" != "$CHECK_SHA" ]]; then
        echo "inactive"
        exit 1
    fi
    echo "$outcome"
    [[ "$outcome" == ok ]] && exit 0 || exit 1
fi

printf 'проект:        %s\n' "$NAME"
printf 'адрес:         https://%s.%s\n' "$NAME" "$SANDBOX_DOMAIN"

if load_project_config "$NAME" "$(app_work_dir "$NAME")" 2>/dev/null; then
    printf 'тип:           %s\n' "$PROJECT_TYPE"
    [[ "$PROJECT_TYPE" == static || "$PROJECT_TYPE" == node ]] && \
        printf 'публикуется:   %s (spa=%s)\n' "$PROJECT_PUBLISH_DIR" "$PROJECT_SPA"
fi

if [[ -n "$CURRENT" ]]; then
    printf 'активный релиз: %s\n' "${CURRENT:0:12}"
else
    printf 'активный релиз: нет — сайт сейчас не раздаётся\n'
fi

if [[ -f "$DEPLOYS" ]]; then
    last=$(tail -1 "$DEPLOYS")
    l_ts=$(cut -f1 <<<"$last"); l_sha=$(cut -f3 <<<"$last")
    l_out=$(cut -f4 <<<"$last"); l_dur=$(cut -f5 <<<"$last")
    printf 'последний деплой: %s  %s  %s  (%s)\n' \
        "${l_sha:0:12}" "$l_out" "$l_ts" "$l_dur"

    if [[ "$l_out" != ok && -n "$CURRENT" && "$l_sha" != "$CURRENT" ]]; then
        printf '\n!! Последняя попытка деплоя провалилась.\n'
        printf '   Отдаётся предыдущий релиз %s, а не %s.\n' \
            "${CURRENT:0:12}" "${l_sha:0:12}"
        printf '   Лог: %s/logs/%s.log\n' "$STATEDIR" "$l_sha"
    fi

    ok_count=$(cut -f4 "$DEPLOYS" | grep -c '^ok$' || true)
    fail_count=$(cut -f4 "$DEPLOYS" | grep -c '^failed$' || true)
    printf 'всего деплоев: %s успешных, %s провалившихся\n' "$ok_count" "$fail_count"
else
    printf 'последний деплой: записей нет\n'
fi

if [[ -d "$(release_root "$NAME")" ]]; then
    printf 'сохранено релизов: %s\n' \
        "$(find "$(release_root "$NAME")" -mindepth 1 -maxdepth 1 -type d | wc -l)"
fi
