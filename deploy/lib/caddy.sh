#!/usr/bin/env bash
# Пер-проектные правила раздачи для Caddy (раздел 5 плана).
# Файл предназначен для source и требует lib/common.sh.
#
# SPA-правила лежат отдельными файлами в /srv/caddy/spa.d/ и импортируются
# внутрь wildcard-блока Caddyfile. Отдельный site-блок на каждый проект не
# годится: он заставил бы Caddy выпускать по сертификату на поддомен вместо
# одного wildcard.

SANDBOX_CADDY_DIR="${SANDBOX_CADDY_DIR:-/srv/caddy}"
SANDBOX_CADDY_SPA_DIR="${SANDBOX_CADDY_SPA_DIR:-$SANDBOX_CADDY_DIR/spa.d}"

# Путь, по которому /srv/sites примонтирован ВНУТРЬ контейнера Caddy.
# Отличается от SANDBOX_SITES_ROOT, который тесты уводят во временный каталог.
SANDBOX_SITES_MOUNT="${SANDBOX_SITES_MOUNT:-/srv/sites}"

# Расширения, для которых fallback на index.html не применяется: отсутствующий
# скрипт или стиль должен возвращать 404, а не HTML-страницу. Иначе браузер
# получает index.html с Content-Type: text/html вместо JS и падает с
# невнятной ошибкой разбора.
SANDBOX_SPA_ASSET_EXTS=(
    '*.js' '*.mjs' '*.cjs' '*.css' '*.map' '*.json' '*.wasm'
    '*.png' '*.jpg' '*.jpeg' '*.gif' '*.svg' '*.ico' '*.webp' '*.avif'
    '*.woff' '*.woff2' '*.ttf' '*.otf' '*.eot'
    '*.mp4' '*.webm' '*.mp3' '*.pdf' '*.zip' '*.txt' '*.xml'
)

spa_snippet_path() { printf '%s/%s.caddy\n' "$SANDBOX_CADDY_SPA_DIR" "$1"; }

# render_spa_snippet <app-name> <domain>
# Печатает содержимое пер-проектного файла правил.
render_spa_snippet() {
    local name=$1 domain=$2

    cat <<EOF
# Сгенерировано автоматически для проекта '$name'. Правки будут перезаписаны
# при следующем деплое; управляется ключом spa= в .sandbox.conf.
@spa_${name} host ${name}.${domain}
handle @spa_${name} {
	root * ${SANDBOX_SITES_MOUNT}/${name}/current

	# Fallback на index.html только для того, что похоже на маршрут
	# приложения: существующие файлы отдаются как есть, а отсутствующие
	# ассеты честно возвращают 404.
	@spa_${name}_route {
		not file
		not path ${SANDBOX_SPA_ASSET_EXTS[*]}
	}
	rewrite @spa_${name}_route /index.html

	file_server
}
EOF
}

# write_spa_snippet <app-name> <domain>
write_spa_snippet() {
    local name=$1 domain=$2 path
    path="$(spa_snippet_path "$name")"
    mkdir -p "$SANDBOX_CADDY_SPA_DIR"
    render_spa_snippet "$name" "$domain" > "$path"
}

# remove_spa_snippet <app-name> — возвращает 0, если файл был удалён.
remove_spa_snippet() {
    local path
    path="$(spa_snippet_path "$1")"
    [[ -f $path ]] || return 1
    rm -f "$path"
}

# caddy_available — запущен ли контейнер Caddy.
# Нужно отличать «конфигурация сломана» от «Caddy сейчас не работает»:
# в первом случае изменения надо откатить, во втором — оставить на диске,
# чтобы они применились при следующем старте.
caddy_available() {
    [[ -d "$SANDBOX_CADDY_DIR" ]] || return 1
    command -v docker >/dev/null 2>&1 || return 1
    ( cd "$SANDBOX_CADDY_DIR" && \
      docker compose ps --status running -q caddy 2>/dev/null | grep -q . )
}

# caddy_validate — проверяет конфиг, не применяя его.
# Валидация ловит синтаксис и неизвестные директивы; сертификаты и DNS-токен
# она не проверяет, но этого достаточно, чтобы не уронить прокси опечаткой.
caddy_validate() {
    ( cd "$SANDBOX_CADDY_DIR" && \
      docker compose exec -T caddy \
        caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile )
}

caddy_reload() {
    # Базовый Caddyfile не содержит маршрутов из Docker labels. Обычный
    # caddy reload затёр бы их. Перезапуск поручает генерацию самому плагину.
    # Цена этого простого механизма — короткий перерыв при смене правил.
    ( cd "$SANDBOX_CADDY_DIR" && \
      docker compose restart caddy )
}

# sync_spa_config <app-name> <true|false> <domain>
# Приводит правила проекта в соответствие с конфигом и перезагружает Caddy.
# Невалидный результат откатывается, чтобы сломанный сниппет не остался
# лежать и не уронил следующий reload — в том числе чужого проекта.
sync_spa_config() {
    local name=$1 spa=$2 domain=$3 path backup="" changed=false
    path="$(spa_snippet_path "$name")"

    if [[ $spa == true ]]; then
        [[ -f $path ]] && backup=$(cat "$path")
        local rendered
        rendered=$(render_spa_snippet "$name" "$domain")
        if [[ "$backup" != "$rendered" ]]; then
            mkdir -p "$SANDBOX_CADDY_SPA_DIR"
            printf '%s\n' "$rendered" > "$path"
            changed=true
        fi
    else
        if [[ -f $path ]]; then
            backup=$(cat "$path")
            rm -f "$path"
            changed=true
        fi
    fi

    [[ $changed == true ]] || return 0

    if ! caddy_available; then
        # Правила остаются на диске: они и есть желаемое состояние, и
        # подхватятся при следующем старте Caddy. Откатывать их здесь
        # означало бы молча потерять настройку проекта.
        warn "[$name] Caddy не запущен — правила раздачи записаны, перезагрузка отложена"
        return 0
    fi

    if ! caddy_validate >/dev/null 2>&1; then
        warn "[$name] конфигурация Caddy не прошла валидацию — откатываю правила"
        if [[ -n $backup ]]; then
            printf '%s\n' "$backup" > "$path"
        else
            rm -f "$path"
        fi
        caddy_validate >/dev/null 2>&1 || warn "[$name] конфигурация Caddy сломана и до изменений"
        return 1
    fi

    caddy_reload >/dev/null || {
        warn "[$name] caddy reload не удался"
        if [[ -n $backup ]]; then
            printf '%s\n' "$backup" > "$path"
        else
            rm -f "$path"
        fi
        return 1
    }

    log "[$name] правила раздачи обновлены (spa=$spa)"
}
