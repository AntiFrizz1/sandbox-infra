#!/usr/bin/env bash
# Тесты SPA-раздачи (раздел 5 плана).
#
# Матчеры Caddy на глаз не проверяются, поэтому тест поднимает настоящий
# Caddy в контейнере и смотрит на реальные HTTP-ответы. Если docker
# недоступен, проверяется хотя бы генерация правил.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/caddy.sh
source "$ROOT/deploy/lib/caddy.sh"

SB=$(make_sandbox)
CONTAINER="sandbox-spa-test-$$"
cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    rm -rf "$SB"
}
trap cleanup EXIT

DOMAIN="sandbox.test.local"
export SANDBOX_CADDY_SPA_DIR="$SB/spa.d"
export SANDBOX_SITES_MOUNT="/srv/sites"

echo "== генерация правил =="
write_spa_snippet spa-app "$DOMAIN"
assert_exists "файл правил создан" "$SB/spa.d/spa-app.caddy"
assert_eq "правила ссылаются на current" "да" \
    "$(grep -q 'root \* /srv/sites/spa-app/current' "$SB/spa.d/spa-app.caddy" && echo да || echo нет)"
assert_eq "матчер именован по проекту" "да" \
    "$(grep -q '@spa_spa-app host spa-app.sandbox.test.local' "$SB/spa.d/spa-app.caddy" && echo да || echo нет)"
assert_eq "ассеты исключены из fallback" "да" \
    "$(grep -q 'not path .*\*\.js' "$SB/spa.d/spa-app.caddy" && echo да || echo нет)"

assert_ok   "удаление правил работает"      remove_spa_snippet spa-app
assert_fail "повторное удаление сообщает, что файла нет" remove_spa_snippet spa-app

echo
echo "== sync_spa_config: реакция на состояние Caddy =="
# Подменяем зависимости от живого Caddy, чтобы проверить ветки решений.
caddy_available() { return "$FAKE_AVAILABLE"; }
caddy_validate()  { return "$FAKE_VALID"; }
caddy_reload()    { FAKE_RELOADED=$((FAKE_RELOADED + 1)); return 0; }

SNIP="$SB/spa.d/app-a.caddy"

FAKE_AVAILABLE=1 FAKE_VALID=0 FAKE_RELOADED=0
assert_ok     "Caddy не запущен — sync не считается ошибкой" \
    sync_spa_config app-a true "$DOMAIN"
assert_exists "правила всё равно записаны на диск" "$SNIP"
assert_eq     "перезагрузки не было" "0" "$FAKE_RELOADED"
rm -f "$SNIP"

FAKE_AVAILABLE=0 FAKE_VALID=0 FAKE_RELOADED=0
assert_ok     "Caddy запущен и конфиг валиден" sync_spa_config app-a true "$DOMAIN"
assert_exists "правила записаны" "$SNIP"
assert_eq     "Caddy перезагружен один раз" "1" "$FAKE_RELOADED"

FAKE_AVAILABLE=0 FAKE_VALID=0 FAKE_RELOADED=0
assert_ok "повторный вызов без изменений ничего не делает" \
    sync_spa_config app-a true "$DOMAIN"
assert_eq "лишней перезагрузки нет" "0" "$FAKE_RELOADED"

# Невалидный конфиг: изменения должны откатиться, а не остаться лежать.
printf 'старое содержимое\n' > "$SNIP"
FAKE_AVAILABLE=0 FAKE_VALID=1 FAKE_RELOADED=0
assert_fail "невалидный конфиг — sync сообщает об ошибке" \
    sync_spa_config app-a true "$DOMAIN"
assert_eq "прежнее содержимое восстановлено" \
    "старое содержимое" "$(cat "$SNIP")"
assert_eq "перезагрузки не было" "0" "$FAKE_RELOADED"

rm -f "$SNIP"
FAKE_AVAILABLE=0 FAKE_VALID=1 FAKE_RELOADED=0
assert_fail "невалидный конфиг при первом включении" \
    sync_spa_config app-a true "$DOMAIN"
assert_missing "новый файл правил удалён" "$SNIP"

unset -f caddy_available caddy_validate caddy_reload
# shellcheck source=deploy/lib/caddy.sh
source "$ROOT/deploy/lib/caddy.sh"

if ! command -v docker >/dev/null 2>&1; then
    echo
    echo "  SKIP проверка реального Caddy: docker недоступен"
    finish
    exit $?
fi

echo
echo "== реальная раздача через Caddy =="

# Сайты: spa-app с SPA-правилами и plain-app без них.
mkdir -p "$SB/sites/spa-app/releases/r1/assets" "$SB/sites/plain-app/releases/r1"
echo "SPA-INDEX"   > "$SB/sites/spa-app/releases/r1/index.html"
echo "APP-BUNDLE"  > "$SB/sites/spa-app/releases/r1/assets/app.js"
echo "PLAIN-INDEX" > "$SB/sites/plain-app/releases/r1/index.html"
ln -s releases/r1 "$SB/sites/spa-app/current"
ln -s releases/r1 "$SB/sites/plain-app/current"

write_spa_snippet spa-app "$DOMAIN"

# Тестовый Caddyfile повторяет структуру боевого: импорт spa.d перед общим
# handle. TLS заменён на обычный HTTP — проверяется маршрутизация, не
# выпуск сертификатов.
cat > "$SB/Caddyfile" <<EOF
{
	admin off
	auto_https off
}

:8080 {
	import /srv/caddy/spa.d/*.caddy

	@app header_regexp app Host ^([a-z0-9]([a-z0-9-]*[a-z0-9])?)\.sandbox\.test\.local\$
	handle @app {
		root * /srv/sites/{re.app.1}/current
		file_server
	}

	handle {
		respond "Unknown sandbox project" 404
	}
}
EOF

if ! docker run -d --name "$CONTAINER" \
        -v "$SB/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "$SB/spa.d:/srv/caddy/spa.d:ro" \
        -v "$SB/sites:/srv/sites:ro" \
        -p 127.0.0.1:8080:8080 \
        caddy:latest >/dev/null 2>&1; then
    echo "  SKIP не удалось запустить контейнер caddy"
    finish
    exit $?
fi

# Ждём, пока Caddy начнёт слушать.
for _ in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 1 -H "Host: plain-app.$DOMAIN" \
        http://127.0.0.1:8080/ 2>/dev/null && break
    sleep 0.5
done

req() {  # req <host> <путь> — печатает "<код> <тело>"
    curl -s -o "$SB/body" -w '%{http_code}' --max-time 5 \
        -H "Host: $1.$DOMAIN" "http://127.0.0.1:8080$2"
}
code() { req "$1" "$2"; }
body() { req "$1" "$2" >/dev/null; cat "$SB/body"; }

echo "-- обычный статический сайт --"
assert_eq "корень отдаётся"            "200" "$(code plain-app /)"
assert_eq "корень отдаёт index.html"   "PLAIN-INDEX" "$(body plain-app /)"
assert_eq "несуществующий маршрут → 404 (а не index.html)" \
    "404" "$(code plain-app /tools/regex)"
assert_eq "несуществующий ассет → 404" "404" "$(code plain-app /assets/nope.js)"

echo
echo "-- SPA --"
assert_eq "корень отдаётся"             "200" "$(code spa-app /)"
assert_eq "существующий ассет отдаётся" "200" "$(code spa-app /assets/app.js)"
assert_eq "ассет отдаёт своё содержимое, а не index.html" \
    "APP-BUNDLE" "$(body spa-app /assets/app.js)"

assert_eq "вложенный маршрут отдаётся"  "200" "$(code spa-app /tools/regex)"
assert_eq "вложенный маршрут отдаёт index.html" \
    "SPA-INDEX" "$(body spa-app /tools/regex)"
assert_eq "глубоко вложенный маршрут тоже" \
    "SPA-INDEX" "$(body spa-app /a/b/c/d)"

assert_eq "ОТСУТСТВУЮЩИЙ .js → 404, а не HTML" \
    "404" "$(code spa-app /assets/missing.js)"
assert_eq "отсутствующий .css → 404"   "404" "$(code spa-app /styles/missing.css)"
assert_eq "отсутствующий .json → 404"  "404" "$(code spa-app /data/missing.json)"
assert_eq "отсутствующий шрифт → 404"  "404" "$(code spa-app /f/missing.woff2)"

echo
echo "-- неизвестный проект --"
assert_eq "поддомен без сайта → 404"   "404" "$(code nosuchapp /)"

echo
echo "== боевой Caddyfile синтаксически корректен =="
# Проверяется структура шаблона вместе с реально сгенерированным сниппетом.
# Блок `tls { dns timeweb ... }` требует плагина, которого нет в официальном
# образе, поэтому он целиком заменяется на `tls internal`.
perl -0pe 's/tls \{\n\s*dns timeweb[^\n]*\n\s*\}/tls internal/' \
    "$ROOT/caddy/Caddyfile" > "$SB/prod-Caddyfile"
assert_eq "подстановка tls сработала" "да" \
    "$(grep -q '^\s*tls internal' "$SB/prod-Caddyfile" && echo да || echo нет)"

# Сниппет генерируется под тот же домен, что и в шаблоне.
mkdir -p "$SB/prod-spa.d"
SANDBOX_CADDY_SPA_DIR="$SB/prod-spa.d" write_spa_snippet myapp sandbox.example.com

docker run --rm \
    -v "$SB/prod-Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$SB/prod-spa.d:/srv/caddy/spa.d:ro" \
    caddy:latest caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile \
    >"$SB/validate.out" 2>&1
rc=$?
assert_eq "caddy validate принимает шаблон вместе со сниппетом" "0" "$rc"
[[ $rc -ne 0 ]] && sed 's/^/       /' "$SB/validate.out" >&2

finish
