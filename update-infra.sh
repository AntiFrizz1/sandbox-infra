#!/usr/bin/env bash
# Обновление уже установленной sandbox-инфраструктуры.
#
# Отличается от bootstrap.sh тем, что НЕ переустанавливает систему и не
# затирает настройки. bootstrap.sh безусловно копировал шаблон поверх
# /srv/caddy/Caddyfile, поэтому после каждого обновления приходилось заново
# вписывать домен.
#
# Здесь домен и email вытаскиваются из действующего конфига и
# подставляются в новый шаблон; результат проверяется `caddy validate`
# и применяется только если проверка прошла.
#
#   ./update-infra.sh                все части
#   ./update-infra.sh --scripts-only только deploy-скрипты
#   ./update-infra.sh --caddy-only   только конфигурацию Caddy
#   ./update-infra.sh --dry-run      показать, что будет сделано
#   ./update-infra.sh -y             без вопросов
set -euo pipefail

SRC_DIR="${SANDBOX_SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=deploy/lib/common.sh
source "$SRC_DIR/deploy/lib/common.sh"
# shellcheck source=deploy/lib/caddy.sh
source "$SRC_DIR/deploy/lib/caddy.sh"

SANDBOX_DEPLOY_DIR="${SANDBOX_DEPLOY_DIR:-/srv/deploy}"
SANDBOX_CADDY_IMAGE="${SANDBOX_CADDY_IMAGE:-sandbox-caddy:latest}"
BACKUP_DIR="${SANDBOX_BACKUP_DIR:-/root/sandbox-backups}"

DO_SCRIPTS=true
DO_CADDY=true
DRY_RUN=false
ASSUME_YES=false
[[ -t 0 ]] || ASSUME_YES=true

for arg in "$@"; do
    case "$arg" in
        --scripts-only) DO_CADDY=false ;;
        --caddy-only)   DO_SCRIPTS=false ;;
        --dry-run)      DRY_RUN=true ;;
        -y|--yes)       ASSUME_YES=true ;;
        -h|--help)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "неизвестный аргумент: $arg" ;;
    esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

confirm() {
    [[ "$ASSUME_YES" == true ]] && return 0
    local ans
    read -rp "$1 [y/N] " ans
    [[ "${ans:-n}" =~ ^[Yy]$ ]]
}

[[ -d "$SANDBOX_DEPLOY_DIR" || -d "$SANDBOX_CADDY_DIR" ]] \
    || die "инфраструктура не установлена — сначала запусти bootstrap.sh"

# --- deploy-скрипты ---------------------------------------------------------
if [[ "$DO_SCRIPTS" == true ]]; then
    log "Обновляю deploy-скрипты в $SANDBOX_DEPLOY_DIR"

    if [[ -d "$SANDBOX_DEPLOY_DIR" ]]; then
        run mkdir -p "$BACKUP_DIR"
        run cp -a "$SANDBOX_DEPLOY_DIR" "$BACKUP_DIR/deploy-$STAMP"
        echo "   бэкап: $BACKUP_DIR/deploy-$STAMP"
    fi

    run mkdir -p "$SANDBOX_DEPLOY_DIR/lib"
    if [[ "$DRY_RUN" == true ]]; then
        printf '   [dry-run] установить: %s\n' "$(cd "$SRC_DIR/deploy" && echo *.sh lib/*.sh)"
    else
        install -m 755 "$SRC_DIR"/deploy/*.sh "$SANDBOX_DEPLOY_DIR/"
        install -m 644 "$SRC_DIR"/deploy/lib/*.sh "$SANDBOX_DEPLOY_DIR/lib/"
        # Симлинки post-receive в bare-репозиториях указывают сюда же,
        # поэтому отдельно их обновлять не нужно.
        if id deploy &>/dev/null; then
            chown -R root:root "$SANDBOX_DEPLOY_DIR"
        fi
    fi
    echo "   готово"
fi

# --- конфигурация Caddy -----------------------------------------------------
if [[ "$DO_CADDY" == true ]]; then
    [[ $DRY_RUN == true ]] || lock_caddy || die "Caddy lock unavailable"
    TEMPLATE="$SRC_DIR/caddy/Caddyfile"
    LIVE="$(caddy_config_path)"

    [[ -f "$TEMPLATE" ]] || die "шаблон не найден: $TEMPLATE"

    log "Обновляю конфигурацию Caddy в $SANDBOX_CADDY_DIR"
    run mkdir -p "$SANDBOX_CADDY_SPA_DIR"
    run set_deploy_owner "$SANDBOX_CADDY_SPA_DIR"

    if [[ ! -f "$LIVE" ]]; then
        warn "действующего Caddyfile нет — копирую шаблон как есть"
        run cp "$TEMPLATE" "$LIVE"
        echo "   !! Впиши свой домен в $LIVE"
    else
        # Домен и email берутся из действующего конфига — ради этого всё и
        # затевалось: обновление не должно требовать повторной правки.
        DOMAIN=$(sed -n 's/^\*\.\([^ ]*\) {.*/\1/p' "$LIVE" | head -1)
        EMAIL=$(sed -n 's/^[[:space:]]*email[[:space:]]\+\([^[:space:]]*\).*/\1/p' "$LIVE" | head -1)

        [[ -n "$DOMAIN" ]] || die "не удалось определить домен из $LIVE.
   Ожидалась строка вида '*.sandbox.example.com {'.
   Обнови конфиг вручную, сверяясь с $TEMPLATE"

        echo "   домен из действующего конфига: $DOMAIN"
        [[ -n "$EMAIL" ]] && echo "   email:  $EMAIL"

        NEW="$(mktemp)"
        trap 'rm -f "$NEW"' EXIT
        # Обычный hostname и hostname внутри regexp имеют разное экранирование.
        # Буквальная подстановка не интерпретирует &, / и обратные слеши email.
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line//sandbox\\.example\\.com/"${DOMAIN//./\\.}"}
            line=${line//sandbox.example.com/"$DOMAIN"}
            line=${line//you@example.com/"${EMAIL:-you@example.com}"}
            printf '%s\n' "$line"
        done < "$TEMPLATE" > "$NEW"

        if cmp -s "$NEW" "$LIVE"; then
            echo "   конфигурация уже актуальна, ничего не меняю"
        else
            echo "   отличия от действующей конфигурации:"
            diff -u "$LIVE" "$NEW" | sed 's/^/     /' || true

            if [[ "$DRY_RUN" == true ]]; then
                echo "   [dry-run] конфиг не изменён"
            elif confirm "   Применить новую конфигурацию Caddy?"; then
                mkdir -p "$BACKUP_DIR"
                cp -a "$LIVE" "$BACKUP_DIR/Caddyfile-$STAMP"
                echo "   бэкап: $BACKUP_DIR/Caddyfile-$STAMP"

                atomic_caddy_file "$LIVE" "$(cat "$NEW")"

                # Проверяем уже установленный файл: именно его прочитает Caddy.
                if caddy_available; then
                    if caddy_validate >/dev/null 2>&1; then
                        echo "   caddy validate: ок"
                        if caddy_reload >/dev/null; then
                            echo "   Caddy перезагружен"
                        else
                            atomic_caddy_file "$LIVE" "$(cat "$BACKUP_DIR/Caddyfile-$STAMP")"
                            caddy_reload >/dev/null 2>&1 || warn "restored config could not be applied"
                            die "Caddy reload failed; previous config restored"
                        fi
                    else
                        warn "новая конфигурация не прошла валидацию — откатываю"
                        atomic_caddy_file "$LIVE" "$(cat "$BACKUP_DIR/Caddyfile-$STAMP")"
                        caddy_validate >/dev/null 2>&1 \
                            || warn "и прежняя конфигурация не валидна — разбирайся вручную"
                        die "конфигурация Caddy не обновлена"
                    fi
                else
                    warn "Caddy не запущен — конфигурация записана, но не проверена и не применена"
                    echo "   Проверь и подними: cd $SANDBOX_CADDY_DIR && docker compose up -d"
                fi
            else
                echo "   пропущено."
            fi
        fi
    fi

    # docker-compose.yml обновляется отдельно: в нём нет пользовательских
    # правок, кроме тех, что пользователь мог внести сам.
    COMPOSE_SRC="$SRC_DIR/caddy/docker-compose.yml"
    COMPOSE_LIVE="$SANDBOX_CADDY_DIR/docker-compose.yml"
    if [[ -f "$COMPOSE_SRC" && -f "$COMPOSE_LIVE" ]] && ! cmp -s "$COMPOSE_SRC" "$COMPOSE_LIVE"; then
        echo "   docker-compose.yml отличается от шаблона:"
        diff -u "$COMPOSE_LIVE" "$COMPOSE_SRC" | sed 's/^/     /' || true
        if [[ "$DRY_RUN" != true ]] && confirm "   Обновить docker-compose.yml?"; then
            run mkdir -p "$BACKUP_DIR"
            run cp -a "$COMPOSE_LIVE" "$BACKUP_DIR/docker-compose-$STAMP.yml"
            run cp "$COMPOSE_SRC" "$COMPOSE_LIVE"
            echo "   обновлён. Применить: cd $SANDBOX_CADDY_DIR && docker compose up -d"
        fi
    fi
fi

echo
log "Обновление завершено."
echo "   .env, состояние проектов, релизы и bare-репозитории не затрагивались."
